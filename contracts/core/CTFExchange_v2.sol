// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "../mixins/Auth.sol";
import "../mixins/OrderStructs.sol";
import "../mixins/FeeManager.sol";
import "../mixins/AssetHelper.sol";
import "../mixins/OrderHashing.sol";
import "../mixins/OrderValidation.sol";
import "../mixins/Trading.sol";
import "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";

contract CTFExchange is
    Trading,              // Trading  Mixin
    ERC1155Holder         //  ERC1155position token IERC1155Receiver
{

    /*//////////////////////////////////////////////////////////////

    //////////////////////////////////////////////////////////////*/

    constructor(
        address conditionalTokens_,
        address collateral_,
        address feeRecipient_,
        uint256 initialTakerFeeRate_,
        uint256 initialMakerFeeRate_
    )
        AssetHelper(conditionalTokens_, collateral_)
    {
        //  Taker/Maker
        _initializeFeeManager(initialTakerFeeRate_, initialMakerFeeRate_, feeRecipient_);

        //
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

        // Operator
    }

    /*//////////////////////////////////////////////////////////////

    //////////////////////////////////////////////////////////////*/

    function setProxyWalletModule(address module)
        external
        onlyAdmin
    {
        require(module != address(0), "Invalid module address");
        proxyWalletModule = IProxyWalletModule(module);
    }

    function setTakerFeeRate(uint256 newRate)
        external
        onlyOperator
    {
        _setTakerFeeRate(newRate);
    }

    function setMakerFeeRate(uint256 newRate)
        external
        onlyOperator
    {
        _setMakerFeeRate(newRate);
    }

    function setFeeRecipient(address newRecipient)
        external
        onlyOperator
    {
        _setFeeRecipient(newRecipient);
    }

    function pause()
        external
        onlyAdmin
    {
        _pause();
    }

    function unpause()
        external
        onlyAdmin
    {
        _unpause();
    }

    function registerTokenPair(
        uint256 tokenId,
        uint256 complementId,
        bytes32 conditionId
    ) external onlyOperator {
        require(conditionId != bytes32(0), "CTFExchange: invalid conditionId");
        require(tokenId != complementId, "CTFExchange: same tokenId");
        require(complementTokens[tokenId] == 0, "CTFExchange: tokenId already registered");
        require(complementTokens[complementId] == 0, "CTFExchange: complementId already registered");

        //
        complementTokens[tokenId] = complementId;
        complementTokens[complementId] = tokenId;

        //  conditionId
        tokenConditions[tokenId] = conditionId;
        tokenConditions[complementId] = conditionId;

        emit TokenPairRegistered(tokenId, complementId, conditionId);
    }

    /*//////////////////////////////////////////////////////////////

    //////////////////////////////////////////////////////////////*/

    function version() external pure returns (string memory) {
        return "2.0.0-mixin";
    }

    function getContractInfo() external view returns (
        address conditionalTokens_,
        address collateral_,
        address feeRecipient_,
        uint256 takerFeeRate_,
        uint256 makerFeeRate_
    ) {
        return (address(conditionalTokens), collateral, feeRecipient, takerFeeRate, makerFeeRate);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(AccessControl, ERC1155Holder)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
