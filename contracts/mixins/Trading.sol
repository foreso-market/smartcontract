// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./OrderValidation.sol";
import "./FeeManager.sol";
import "./AssetHelper.sol";
import "./Auth.sol";
import "../interfaces/IProxyWalletModule.sol";

abstract contract Trading is
    OrderValidation,  //  OrderStructs, OrderHashing
    FeeManager,
    AssetHelper,
    Auth,
    ReentrancyGuard,
    Pausable
{
    using SafeERC20 for IERC20;
    /*//////////////////////////////////////////////////////////////

    //////////////////////////////////////////////////////////////*/

    uint256 internal constant ONE = 10 ** 18;

    /*//////////////////////////////////////////////////////////////

    //////////////////////////////////////////////////////////////*/

    event TokenPairRegistered(
        uint256 indexed tokenId,
        uint256 indexed complementId,
        bytes32 indexed conditionId
    );

    /*//////////////////////////////////////////////////////////////
                             matchOrders
    //////////////////////////////////////////////////////////////*/

    mapping(uint256 => uint256) public complementTokens;

    mapping(uint256 => bytes32) public tokenConditions;

    IProxyWalletModule public proxyWalletModule;

    /*//////////////////////////////////////////////////////////////

    //////////////////////////////////////////////////////////////*/

    function recordFill(
        Order calldata order,
        bytes calldata /* signature */,
        uint256 fillAmount
    ) external onlyOperator nonReentrant whenNotPaused {
        // 1.
        bytes32 orderHash = _hashOrder(order);

        // 2.
        _validateOrder(orderHash, order);
        _validateFeeRate(order.feeRateBps);

        // 3.
        uint256 remaining = order.makerAmount - filled[orderHash];
        if (fillAmount > remaining) revert InvalidAmount(fillAmount, remaining);
        if (fillAmount == 0) revert InvalidAmount(0, remaining);

        // 4.  taker
        uint256 takerFillAmount = (fillAmount * order.takerAmount) / order.makerAmount;
        if (takerFillAmount == 0) revert InvalidAmount(0, 1);

        // 5.  Taker
        uint256 fee = _calculateTakerFee(takerFillAmount);

        // 6.
        filled[orderHash] += fillAmount;

        // 7.
        (uint256 makerAssetId, uint256 takerAssetId) = _deriveAssetIds(order);
        emit OrderFilled(
            orderHash,
            order.maker,
            msg.sender,
            makerAssetId,
            takerAssetId,
            fillAmount,
            takerFillAmount,
            fee
        );
    }

    /*//////////////////////////////////////////////////////////////

    //////////////////////////////////////////////////////////////*/

    function cancelOrder(Order calldata order) external {
        require(msg.sender == order.maker, "Trading: only maker can cancel");

        bytes32 orderHash = _hashOrder(order);
        require(!cancelled[orderHash], "Trading: already cancelled");

        cancelled[orderHash] = true;

        emit OrderCancelled(orderHash);
    }

    /*//////////////////////////////////////////////////////////////
                    matchOrders
    //////////////////////////////////////////////////////////////*/

    function matchOrders(
        Order calldata takerOrder,
        Order[] calldata makerOrders,
        uint256 takerFillAmount,
        uint256[] calldata makerFillAmounts
    ) external onlyOperator nonReentrant whenNotPaused {
        require(
            makerOrders.length == makerFillAmounts.length,
            "Trading: array length mismatch"
        );

        _matchOrders(takerOrder, makerOrders, takerFillAmount, makerFillAmounts);
    }

    function _matchOrders(
        Order calldata takerOrder,
        Order[] calldata makerOrders,
        uint256 takerFillAmount,
        uint256[] calldata makerFillAmounts
    ) internal {
        // 0. matchOrders  Safe  EOA
        require(
            takerOrder.signatureType == SignatureType.POLY_GNOSIS_SAFE ||
            takerOrder.signatureType == SignatureType.FORESO_1271,
            "Trading: EOA orders not supported in matchOrders"
        );

        // 1.  Taker
        bytes32 structHash = _hashOrder(takerOrder);
        _validateOrder(structHash, takerOrder);
        _validateFeeRate(takerOrder.feeRateBps);

        // 2.  ID
        (uint256 makerAssetId, uint256 takerAssetId) = _deriveAssetIds(takerOrder);

        // 3.  EIP-712
        bytes32 orderHash = _hashTypedDataV4(structHash);

        // 4.  Taker  Exchange
        _transferToExchange(takerOrder.maker, makerAssetId, takerFillAmount, takerOrder, orderHash);

        // 5.  Maker
        uint256 totalMakerTaking = 0;
        uint256 totalMakerFillAmount = 0;
        for (uint256 i = 0; i < makerOrders.length; i++) {
            uint256 taking = _fillMakerOrder(
                takerOrder,
                makerOrders[i],
                makerFillAmounts[i]
            );
            totalMakerTaking += taking;
            totalMakerFillAmount += makerFillAmounts[i];
        }

        // 6. ⭐  _getBalance
        //     +
        //     splitPosition/mergePositions/transfer  revert
        uint256 takerReceiveAmount;
        uint256 refund;
        uint256 derivedTakerFill;

        bool isSameSide = makerOrders.length > 0 && makerOrders[0].side == takerOrder.side;
        if (isSameSide) {
            if (takerOrder.side == Side.BUY) {
                // MINT: taker(USDC) + maker(USDC) → splitPosition → YES + NO tokens
                // taker  tokenrefund  USDC
                takerReceiveAmount = totalMakerTaking;
                refund = takerFillAmount + totalMakerFillAmount - totalMakerTaking;
                derivedTakerFill = totalMakerTaking - totalMakerFillAmount;
            } else {
                // MERGE: taker(YES) + maker(NO) → mergePositions → USDC
                // taker  USDC maker refund  token
                takerReceiveAmount = totalMakerFillAmount - totalMakerTaking;
                refund = takerFillAmount - totalMakerFillAmount;
                derivedTakerFill = totalMakerFillAmount;
            }
        } else {
            // STANDARD: taker  maker
            takerReceiveAmount = totalMakerFillAmount;
            refund = takerFillAmount - totalMakerTaking;
            derivedTakerFill = totalMakerTaking;
        }

        // 7.  USDT
        uint256 effectiveFeeRate = takerOrder.feeRateBps > 0 ? takerOrder.feeRateBps : takerFeeRate;
        uint256 takerUsdtAmount = takerOrder.side == Side.BUY ? derivedTakerFill : takerReceiveAmount;
        uint256 fee = _calculateFeeWithRate(takerUsdtAmount, effectiveFeeRate);

        // 8.
        filled[structHash] += derivedTakerFill;

        // 9.  Taker
        if (takerReceiveAmount > 0) {
            _transferFromExchange(takerOrder.maker, takerAssetId, takerReceiveAmount);
        }

        // 10.  USDT
        if (fee > 0) {
            bytes32 takerOrderHash = _hashTypedDataV4(structHash);
            _collectUSDTFee(takerOrder.maker, fee, takerOrder, takerOrderHash);
        }

        // 11.
        if (refund > 0) {
            _transferFromExchange(takerOrder.maker, makerAssetId, refund);
        }

        // 12.
        emit OrdersMatched(
            structHash,
            takerOrder.maker,
            makerAssetId,
            takerAssetId,
            derivedTakerFill,
            takerReceiveAmount
        );
    }

    function _fillMakerOrder(
        Order calldata takerOrder,
        Order calldata makerOrder,
        uint256 fillAmount
    ) internal returns (uint256 taking) {
        // 1.
        MatchType matchType = _deriveMatchType(takerOrder, makerOrder);

        // 2.
        _validateTakerAndMaker(takerOrder, makerOrder, matchType);

        // 2.5 Maker  Safe
        require(
            makerOrder.signatureType == SignatureType.POLY_GNOSIS_SAFE ||
            makerOrder.signatureType == SignatureType.FORESO_1271,
            "Trading: EOA orders not supported in matchOrders"
        );

        // 3.  Maker
        bytes32 structHash = _hashOrder(makerOrder);
        _validateOrder(structHash, makerOrder);
        _validateFeeRate(makerOrder.feeRateBps);

        // 4.
        uint256 remaining = _getRemainingAmount(makerOrder, structHash);
        if (fillAmount > remaining) revert InvalidAmount(fillAmount, remaining);
        if (fillAmount == 0) revert InvalidAmount(0, remaining);

        // 5.
        taking = (fillAmount * makerOrder.takerAmount) / makerOrder.makerAmount;
        if (taking == 0) revert InvalidAmount(0, 1);

        // 6. ⭐  USDT
        //  USDT
        uint256 effectiveFeeRate = makerOrder.feeRateBps > 0 ? makerOrder.feeRateBps : makerFeeRate;
        // BUY: makerAmount  USDTSELL: taking  USDT
        uint256 usdtAmount = makerOrder.side == Side.BUY ? fillAmount : taking;
        uint256 fee = _calculateFeeWithRate(usdtAmount, effectiveFeeRate);

        // 7.  ID
        (uint256 makerAssetId, uint256 takerAssetId) = _deriveAssetIds(makerOrder);

        // 8.  EIP-712
        bytes32 orderHash = _hashTypedDataV4(structHash);

        // 9. Checks-Effects-Interactions:
        filled[structHash] += fillAmount;

        // 10.  MINT/MERGE
        _executeMatch(
            fillAmount,
            taking,
            makerOrder.maker,
            makerAssetId,
            takerAssetId,
            matchType,
            fee,
            makerOrder,
            orderHash
        );

        // 11.
        emit OrderFilled(
            structHash,
            makerOrder.maker,
            takerOrder.maker,
            makerAssetId,
            takerAssetId,
            fillAmount,
            taking,
            fee
        );

        return taking;
    }

    function _deriveMatchType(
        Order calldata takerOrder,
        Order calldata makerOrder
    ) internal pure returns (MatchType) {
        if (takerOrder.side == Side.BUY && makerOrder.side == Side.BUY) {
            return MatchType.MINT;
        }
        if (takerOrder.side == Side.SELL && makerOrder.side == Side.SELL) {
            return MatchType.MERGE;
        }
        return MatchType.COMPLEMENTARY;
    }

    function _deriveAssetIds(Order calldata order)
        internal
        pure
        returns (uint256 makerAssetId, uint256 takerAssetId)
    {
        if (order.side == Side.BUY) {
            // BUY: makerAssetId=0(collateral), takerAssetId=tokenId
            return (0, order.tokenId);
        } else {
            // SELL: makerAssetId=tokenId, takerAssetId=0(collateral)
            return (order.tokenId, 0);
        }
    }

    function _isCrossing(
        Order calldata takerOrder,
        Order calldata makerOrder
    ) internal pure returns (bool) {
        // takerAmount  0
        if (takerOrder.takerAmount == 0 || makerOrder.takerAmount == 0) revert InvalidAmount(0, 1);

        //  side
        uint256 takerPrice = _calculatePrice(takerOrder.makerAmount, takerOrder.takerAmount, takerOrder.side);
        uint256 makerPrice = _calculatePrice(makerOrder.makerAmount, makerOrder.takerAmount, makerOrder.side);

        //
        if (takerOrder.side == Side.BUY) {
            if (makerOrder.side == Side.BUY) {
                // BUY vs BUY (MINT):  >= 1.0
                return takerPrice + makerPrice >= ONE;
            }
            // BUY vs SELL (STANDARD): BUY >= SELL
            return takerPrice >= makerPrice;
        }

        if (makerOrder.side == Side.BUY) {
            // SELL vs BUY (STANDARD): BUY >= SELL
            return makerPrice >= takerPrice;
        }

        // SELL vs SELL (MERGE):  <= 1.0
        return takerPrice + makerPrice <= ONE;
    }

    function _calculatePrice(
        uint256 makerAmount,
        uint256 takerAmount,
        Side side
    ) internal pure returns (uint256) {
        if (side == Side.BUY) {
            // BUY: price = makerAmount / takerAmount (USDC per token)
            return takerAmount != 0 ? (makerAmount * ONE) / takerAmount : 0;
        }
        // SELL: price = takerAmount / makerAmount (USDC per token)
        return makerAmount != 0 ? (takerAmount * ONE) / makerAmount : 0;
    }

    function _validateTakerAndMaker(
        Order calldata takerOrder,
        Order calldata makerOrder,
        MatchType matchType
    ) internal view {
        if (!_isCrossing(takerOrder, makerOrder)) revert NotCrossing();

        if (matchType == MatchType.COMPLEMENTARY) {
            if (takerOrder.tokenId != makerOrder.tokenId) {
                revert MismatchedTokenIds();
            }
        } else {
            // MINT/MERGE tokenId (YES ↔ NO)
            if (complementTokens[takerOrder.tokenId] != makerOrder.tokenId) {
                revert MismatchedTokenIds();
            }
        }
    }

    function _executeMatch(
        uint256 makingAmount,
        uint256 takingAmount,
        address maker,
        uint256 makerAssetId,
        uint256 takerAssetId,
        MatchType matchType,
        uint256 fee,
        Order calldata order,
        bytes32 orderHash
    ) internal {
        // 1. Maker  Exchange
        _transferToExchange(maker, makerAssetId, makingAmount, order, orderHash);

        // 2.
        if (matchType == MatchType.COMPLEMENTARY) {
            // STANDARD

        } else if (matchType == MatchType.MINT) {
            //  vs  Polymarket
            // MINT: Taker  Maker  collateralYES/NO
            // Taker BUY YES: makerAssetId=0, takerAssetId=YES tokenId
            // Maker BUY NO:  makerAssetId=0, takerAssetId=NO tokenId

            // ⭐ Polymarket:  takerAssetId  conditionId
            bytes32 conditionId = tokenConditions[takerAssetId];
            require(conditionId != bytes32(0), "Trading: token not registered");

            // ⭐ Polymarket:  [1, 2]  [YES, NO]
            uint256[] memory partition = new uint256[](2);
            partition[0] = 1;
            partition[1] = 2;

            // ⭐ Polymarket: MINT  takingAmountMaker  tokens  USDC
            // takingAmount: Maker  takingAmount Maker  tokens
            // Exchange  Taker + Maker  USDC takingAmount  tokens
            conditionalTokens.splitPosition(
                IERC20(collateral),
                bytes32(0),  // parentCollectionId
                conditionId,
                partition,
                takingAmount  // ⭐  takingAmount  Polymarket
            );

        } else if (matchType == MatchType.MERGE) {
            //  vs  Polymarket
            // MERGE: Taker  Maker  position token collateral

            // ⭐ Polymarket:  makerAssetId  conditionId
            bytes32 conditionId = tokenConditions[makerAssetId];
            require(conditionId != bytes32(0), "Trading: token not registered");

            // ⭐ Polymarket:  [1, 2]  [YES, NO]
            uint256[] memory partition = new uint256[](2);
            partition[0] = 1;
            partition[1] = 2;

            // ⭐ Polymarket: MERGE  makingAmount position token
            conditionalTokens.mergePositions(
                IERC20(collateral),
                bytes32(0),  // parentCollectionId
                conditionId,
                partition,
                makingAmount
            );
        }

        // 3.  Exchange  takerAssetId
        uint256 balance = _getBalance(takerAssetId);
        if (balance < takingAmount) revert TooLittleTokensReceived();

        // 4.  Maker
        _transferAsset(address(this), maker, takerAssetId, takingAmount);

        // 5. ⭐  USDT
        if (fee > 0) {
            //  Maker  ProxyWallet  USDT
            _collectUSDTFee(maker, fee, order, orderHash);
        }
    }

    function _transferToExchange(
        address from,
        uint256 assetId,
        uint256 amount,
        Order calldata order,
        bytes32 orderHash
    ) internal {
        if (_isERC1155TokenId(assetId)) {
            // ERC1155  - Safe
            proxyWalletModule.transferERC1155ForOrder(
                from,  // safe
                address(conditionalTokens),
                address(this),
                assetId,
                amount,
                orderHash,
                order.makerAmount,
                order.expiration,
                order.signature
            );
        } else {
            // ERC20 (USDC)  - Safe
            proxyWalletModule.transferERC20ForOrder(
                from,  // safe
                collateral,
                address(this),
                amount,
                orderHash,
                order.makerAmount,
                order.expiration,
                order.signature
            );
        }
    }

    function _transferFromExchange(address to, uint256 assetId, uint256 amount) internal {
        if (_isERC1155TokenId(assetId)) {
            _transferERC1155(address(this), to, assetId, amount);
        } else {
            _transferCollateral(address(this), to, amount);
        }
    }

    function _getBalance(uint256 assetId) internal view returns (uint256) {
        if (_isERC1155TokenId(assetId)) {
            return conditionalTokens.balanceOf(address(this), assetId);
        } else {
            return IERC20(collateral).balanceOf(address(this));
        }
    }

    function _collectUSDTFee(
        address from,
        uint256 fee,
        Order calldata order,
        bytes32 orderHash
    ) internal {
        if (fee == 0 || feeRecipient == address(0)) return;

        // Safe :  ProxyWalletModule
        proxyWalletModule.transferFeeForOrder(
            from,  // safe
            collateral,
            feeRecipient,
            fee,
            orderHash,
            order.makerAmount,
            order.expiration,
            order.signature
        );
    }
}
