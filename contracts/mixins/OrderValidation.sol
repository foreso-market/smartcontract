// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "./OrderStructs.sol";
import "./OrderHashing.sol";

interface IGnosisSafeOwner {
    function isOwner(address owner) external view returns (bool);
}

interface IERC1271 {
    function isValidSignature(bytes32 hash, bytes memory signature) external view returns (bytes4);
}

abstract contract OrderValidation is OrderStructs, OrderHashing {
    using ECDSA for bytes32;

    /*//////////////////////////////////////////////////////////////

    //////////////////////////////////////////////////////////////*/

    mapping(bytes32 => uint256) public filled;

    mapping(bytes32 => bool) public cancelled;

    /*//////////////////////////////////////////////////////////////

    //////////////////////////////////////////////////////////////*/

    function validateOrderSignature(
        Order calldata order,
        bytes calldata signature
    ) public view returns (bool) {
        bytes32 structHash = _hashOrder(order);
        bytes32 digest = _hashTypedDataV4(structHash);
        address recovered = digest.recover(signature);

        if (recovered != order.signer) {
            return false;
        }

        if (order.signatureType == SignatureType.EOA) {
            return order.signer == order.maker;

        } else if (order.signatureType == SignatureType.POLY_GNOSIS_SAFE) {
            try IGnosisSafeOwner(order.maker).isOwner(order.signer) returns (bool isOwner) {
                return isOwner;
            } catch {
                return false;
            }

        } else if (order.signatureType == SignatureType.FORESO_1271) {
            bytes4 MAGIC_VALUE = 0x1626ba7e;
            try IERC1271(order.maker).isValidSignature(digest, signature) returns (bytes4 result) {
                return result == MAGIC_VALUE;
            } catch {
                return false;
            }
        }

        return false;
    }

    /*//////////////////////////////////////////////////////////////

    //////////////////////////////////////////////////////////////*/

    function _validateOrder(bytes32 orderHash, Order calldata order) internal view {
        // 1.
        if (cancelled[orderHash]) {
            revert OrderAlreadyCancelled(orderHash);
        }

        // 1.5  EOA / POLY_PROXY  Safe  (OVA-17)
        require(
            order.signatureType == SignatureType.POLY_GNOSIS_SAFE ||
            order.signatureType == SignatureType.FORESO_1271,
            "OrderValidation: EOA orders not supported"
        );

        // 2.
        if (!validateOrderSignature(order, order.signature)) {
            //
            bytes32 structHash = _hashOrder(order);
            bytes32 digest = _hashTypedDataV4(structHash);
            address recovered = digest.recover(order.signature);
            revert InvalidSignature(recovered, order.signer, order.maker);
        }

        // 3.
        if (order.expiration > 0 && order.expiration < block.timestamp) {
            revert OrderExpired(order.expiration, block.timestamp);
        }

        // 4.
        if (filled[orderHash] >= order.makerAmount) {
            revert OrderFullyFilled(orderHash, filled[orderHash], order.makerAmount);
        }
    }

    /*//////////////////////////////////////////////////////////////

    //////////////////////////////////////////////////////////////*/

    function getOrderStatus(bytes32 orderHash)
        external
        view
        returns (uint256 filledAmount, bool isCancelled)
    {
        return (filled[orderHash], cancelled[orderHash]);
    }

    function _getRemainingAmount(
        Order calldata order,
        bytes32 orderHash
    ) internal view returns (uint256) {
        uint256 filledAmount = filled[orderHash];
        if (filledAmount >= order.makerAmount) {
            return 0;
        }
        return order.makerAmount - filledAmount;
    }
}
