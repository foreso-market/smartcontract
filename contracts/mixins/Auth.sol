// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/access/AccessControl.sol";

abstract contract Auth is AccessControl {

    /*//////////////////////////////////////////////////////////////

    //////////////////////////////////////////////////////////////*/

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    /*//////////////////////////////////////////////////////////////

    //////////////////////////////////////////////////////////////*/

    event OperatorAdded(address indexed operator, address indexed admin);

    event OperatorRemoved(address indexed operator, address indexed admin);

    /*//////////////////////////////////////////////////////////////

    //////////////////////////////////////////////////////////////*/

    error NotOperator();

    error NotAdmin();

    /*//////////////////////////////////////////////////////////////

    //////////////////////////////////////////////////////////////*/

    modifier onlyOperator() {
        if (!hasRole(OPERATOR_ROLE, msg.sender)) {
            revert NotOperator();
        }
        _;
    }

    modifier onlyAdmin() {
        if (!hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            revert NotAdmin();
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////

    //////////////////////////////////////////////////////////////*/

    function addOperator(address operator) external onlyAdmin {
        require(operator != address(0), "Auth: operator is zero address");
        _grantRole(OPERATOR_ROLE, operator);
        emit OperatorAdded(operator, msg.sender);
    }

    function removeOperator(address operator) external onlyAdmin {
        _revokeRole(OPERATOR_ROLE, operator);
        emit OperatorRemoved(operator, msg.sender);
    }

    function isOperator(address account) external view returns (bool) {
        return hasRole(OPERATOR_ROLE, account);
    }

    function isAdmin(address account) external view returns (bool) {
        return hasRole(DEFAULT_ADMIN_ROLE, account);
    }
}
