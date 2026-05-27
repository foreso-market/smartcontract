// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "./OrderStructs.sol";

abstract contract OrderHashing is EIP712, OrderStructs {

    /*//////////////////////////////////////////////////////////////

    //////////////////////////////////////////////////////////////*/

    constructor() EIP712("CTFExchange", "1") {}

    /*//////////////////////////////////////////////////////////////

    //////////////////////////////////////////////////////////////*/

    function _hashOrder(Order calldata order) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                ORDER_TYPEHASH,
                order.salt,           // ⭐ Polymarket: salt
                order.maker,
                order.signer,
                order.taker,
                order.tokenId,        // ⭐ Polymarket:  tokenId
                order.makerAmount,
                order.takerAmount,
                order.expiration,
                order.nonce,          // ⭐
                order.feeRateBps,     // ⭐
                order.side,           // enum  uint8
                order.signatureType   // enum  uint8
            )
        );
    }

    function getOrderHash(Order calldata order) external view returns (bytes32) {
        bytes32 structHash = _hashOrder(order);
        return _hashTypedDataV4(structHash);
    }
}
