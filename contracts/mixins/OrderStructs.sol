// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

abstract contract OrderStructs {

    /*//////////////////////////////////////////////////////////////

    //////////////////////////////////////////////////////////////*/

    enum Side {
        BUY,   // 0:  position token collateral
        SELL   // 1:  position token collateral
    }

    enum SignatureType {
        EOA,                // 0:  EOA signer  maker
        POLY_PROXY,         // 1: EOA maker signer
        POLY_GNOSIS_SAFE,   // 2: Gnosis Safe
        FORESO_1271         // 3: EIP-1271
    }

    enum MatchType {
        COMPLEMENTARY,  // 0:  vs
        MINT,           // 1:  vs
        MERGE           // 2:  vs
    }

    /*//////////////////////////////////////////////////////////////

    //////////////////////////////////////////////////////////////*/

    struct Order {
        uint256 salt;
        address maker;
        address signer;
        address taker;
        uint256 tokenId;        // ⭐ Polymarket:  tokenId
        uint256 makerAmount;
        uint256 takerAmount;
        uint256 expiration;
        uint256 nonce;          // ⭐
        uint256 feeRateBps;     // ⭐
        Side side;              // ⭐ BUY/SELL
        SignatureType signatureType;
        bytes signature;        // ⭐  Polymarket
    }

    /*//////////////////////////////////////////////////////////////

    //////////////////////////////////////////////////////////////*/

    bytes32 public constant ORDER_TYPEHASH = keccak256(
        "Order(uint256 salt,address maker,address signer,address taker,uint256 tokenId,uint256 makerAmount,uint256 takerAmount,uint256 expiration,uint256 nonce,uint256 feeRateBps,uint8 side,uint8 signatureType)"
    );

    /*//////////////////////////////////////////////////////////////

    //////////////////////////////////////////////////////////////*/

    event OrderFilled(
        bytes32 indexed orderHash,
        address indexed maker,
        address indexed taker,
        uint256 makerAssetId,
        uint256 takerAssetId,
        uint256 makerAmountFilled,
        uint256 takerAmountFilled,
        uint256 fee
    );

    event OrderCancelled(bytes32 indexed orderHash);

    event OrdersMatched(
        bytes32 indexed orderHash,
        address indexed maker,
        uint256 makerAssetId,
        uint256 takerAssetId,
        uint256 makerAmount,
        uint256 takerAmount
    );

    /*//////////////////////////////////////////////////////////////

    //////////////////////////////////////////////////////////////*/

    error InvalidSignature(address recovered, address expected, address maker);

    error OrderExpired(uint256 expiration, uint256 currentTime);

    error OrderAlreadyCancelled(bytes32 orderHash);

    error OrderFullyFilled(bytes32 orderHash, uint256 filled, uint256 total);

    error InvalidTaker(address actual, address expected);

    error InvalidAmount(uint256 requested, uint256 available);

    error InsufficientBalance(address account, uint256 required, uint256 actual);

    error InvalidSide();

    error NotCrossing();

    error MismatchedTokenIds();

    error TooLittleTokensReceived();

    error MakingGtRemaining();

    error OrderAlreadyFilled();

    error InvalidNonce();
}
