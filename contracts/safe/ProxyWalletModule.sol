// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

interface IGnosisSafe {
    enum Operation { Call, DelegateCall }

    function execTransactionFromModule(
        address to,
        uint256 value,
        bytes memory data,
        Operation operation
    ) external returns (bool success);

    function isOwner(address owner) external view returns (bool);

    function getOwners() external view returns (address[] memory);
}

interface ICTFAdapter {
    function mergeAndReturn(
        IERC20 collateralToken,
        bytes32 conditionId,
        uint256 amount,
        address recipient
    ) external;
}

contract ProxyWalletModule is ReentrancyGuard, EIP712, Ownable {
    using SafeERC20 for IERC20;
    using ECDSA for bytes32;

    mapping(address => bool) public operators;

    mapping(address => mapping(address => bool)) public allowedTargets;

    mapping(address => mapping(bytes32 => uint256)) public orderConsumed;

    mapping(address => mapping(bytes32 => address)) public orderSigner;

    mapping(address => mapping(bytes32 => uint256)) public orderTotalAmount;

    mapping(address => mapping(bytes32 => uint256)) public feeConsumed;

    uint256 public constant MAX_FEE_RATE_BPS = 200;
    uint256 private constant BPS_DIVISOR = 10000;

    mapping(address => mapping(uint256 => bool)) public usedNonces;

    bytes32 public constant WITHDRAW_REQUEST_TYPEHASH = keccak256(
        "WithdrawRequest(address safe,address token,address to,uint256 amount,uint256 nonce,uint256 deadline)"
    );

    bytes32 public constant MINT_PERMIT_TYPEHASH = keccak256(
        "MintPermit(address safe,address collateralToken,address ctfAdapter,bytes32 conditionId,uint256 amount,uint256 nonce,uint256 deadline)"
    );

    bytes32 public constant MERGE_PERMIT_TYPEHASH = keccak256(
        "MergePermit(address safe,address conditionalTokens,address ctfAdapter,address collateralToken,bytes32 conditionId,uint256[] positionIds,uint256 amount,uint256 nonce,uint256 deadline)"
    );

    address public ctfExchange;

    mapping(address => bool) public operatorTargets;

    event OperatorAdded(address indexed operator);
    event OperatorRemoved(address indexed operator);
    event AllowedTargetUpdated(address indexed safe, address indexed target, bool allowed);
    event ERC20Transferred(address indexed safe, address indexed token, address indexed to, uint256 amount);
    event ERC1155Transferred(address indexed safe, address indexed token, address indexed to, uint256 tokenId, uint256 amount);
    event ERC20Approved(address indexed safe, address indexed token, address indexed spender, uint256 amount);
    event Executed(address indexed safe, address indexed target, uint256 value, bytes data);
    event TransferForOrder(address indexed safe, bytes32 indexed orderHash, address token, address to, uint256 amount);
    event MintWithPermit(address indexed safe, address indexed ctfAdapter, bytes32 indexed conditionId, uint256 amount);
    event MergeWithPermit(address indexed safe, address indexed ctfAdapter, bytes32 indexed conditionId, uint256 amount);

    error UnauthorizedOperator();
    error UnauthorizedOwner();
    error ZeroAddress();
    error TargetNotAllowed();
    error InvalidSignature();
    error NonceAlreadyUsed();
    error ExpiredDeadline();
    error ExceedsOrderAmount();
    error ExceedsFeeLimit();
    error ExecutionFailed();
    error NotExchange();

    constructor() EIP712("ProxyWalletModule", "1") Ownable(msg.sender) {}

    // ====================  ====================

    modifier onlyOperator() {
        if (!operators[msg.sender] && msg.sender != owner()) {
            revert UnauthorizedOperator();
        }
        _;
    }

    modifier onlyExchange() {
        if (msg.sender != ctfExchange) revert NotExchange();
        _;
    }

    modifier onlySafeOwner(address safe) {
        if (!IGnosisSafe(safe).isOwner(msg.sender) && !operators[msg.sender] && msg.sender != owner()) {
            revert UnauthorizedOwner();
        }
        _;
    }

    modifier onlyStrictSafeOwner(address safe) {
        if (!IGnosisSafe(safe).isOwner(msg.sender)) {
            revert UnauthorizedOwner();
        }
        _;
    }

    // ====================  ====================

    function addOperator(address operator) external onlyOwner {
        if (operator == address(0)) revert ZeroAddress();
        operators[operator] = true;
        emit OperatorAdded(operator);
    }

    function removeOperator(address operator) external onlyOwner {
        operators[operator] = false;
        emit OperatorRemoved(operator);
    }

    function setCTFExchange(address _exchange) external onlyOwner {
        if (_exchange == address(0)) revert ZeroAddress();
        ctfExchange = _exchange;
    }

    function setOperatorTarget(address target, bool allowed) external onlyOwner {
        if (target == address(0)) revert ZeroAddress();
        operatorTargets[target] = allowed;
    }

    // ====================  ====================

    function setAllowedTarget(address safe, address target, bool allowed) external onlyStrictSafeOwner(safe) {
        if (target == address(0)) revert ZeroAddress();
        allowedTargets[safe][target] = allowed;
        emit AllowedTargetUpdated(safe, target, allowed);
    }

    function batchSetAllowedTargets(address safe, address[] calldata targets) external onlyStrictSafeOwner(safe) {
        for (uint256 i = 0; i < targets.length; i++) {
            if (targets[i] != address(0)) {
                allowedTargets[safe][targets[i]] = true;
                emit AllowedTargetUpdated(safe, targets[i], true);
            }
        }
    }

    bytes32 public constant WHITELIST_PERMIT_TYPEHASH = keccak256(
        "WhitelistPermit(address safe,address[] targets,uint256 nonce,uint256 deadline)"
    );

    function batchSetAllowedTargetsWithSignature(
        address safe,
        address[] calldata targets,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external onlyOperator {
        if (block.timestamp > deadline) revert ExpiredDeadline();
        if (usedNonces[safe][nonce]) revert NonceAlreadyUsed();

        bytes32 structHash = keccak256(abi.encode(
            WHITELIST_PERMIT_TYPEHASH,
            safe,
            keccak256(abi.encodePacked(targets)),
            nonce,
            deadline
        ));

        bytes32 digest = _hashTypedDataV4(structHash);
        address signer = ECDSA.recover(digest, signature);
        if (!IGnosisSafe(safe).isOwner(signer)) revert InvalidSignature();

        usedNonces[safe][nonce] = true;

        for (uint256 i = 0; i < targets.length; i++) {
            if (targets[i] != address(0)) {
                allowedTargets[safe][targets[i]] = true;
                emit AllowedTargetUpdated(safe, targets[i], true);
            }
        }
    }

    // ==================== ERC20  ====================

    function approveERC20(
        address safe,
        address token,
        address spender,
        uint256 amount
    ) external onlyOperator {
        if (spender == address(0)) revert ZeroAddress();

        bytes memory data = abi.encodeWithSelector(
            IERC20.approve.selector,
            spender,
            amount
        );

        bool success = IGnosisSafe(safe).execTransactionFromModule(
            token,
            0,
            data,
            IGnosisSafe.Operation.Call
        );

        if (!success) revert ExecutionFailed();
        emit ERC20Approved(safe, token, spender, amount);
    }

    function transferERC20(
        address safe,
        address token,
        address to,
        uint256 amount
    ) external onlySafeOwner(safe) nonReentrant {
        if (to == address(0)) revert ZeroAddress();

        bytes memory data = abi.encodeWithSelector(
            IERC20.transfer.selector,
            to,
            amount
        );

        bool success = IGnosisSafe(safe).execTransactionFromModule(
            token,
            0,
            data,
            IGnosisSafe.Operation.Call
        );

        if (!success) revert ExecutionFailed();
        emit ERC20Transferred(safe, token, to, amount);
    }

    // ==================== ERC1155  ====================

    function transferERC1155(
        address safe,
        address token,
        address to,
        uint256 tokenId,
        uint256 amount
    ) external onlySafeOwner(safe) nonReentrant {
        if (to == address(0)) revert ZeroAddress();

        bytes memory data = abi.encodeWithSelector(
            IERC1155.safeTransferFrom.selector,
            safe,
            to,
            tokenId,
            amount,
            ""
        );

        bool success = IGnosisSafe(safe).execTransactionFromModule(
            token,
            0,
            data,
            IGnosisSafe.Operation.Call
        );

        if (!success) revert ExecutionFailed();
        emit ERC1155Transferred(safe, token, to, tokenId, amount);
    }

    function setApprovalForAllERC1155(
        address safe,
        address token,
        address operator,
        bool approved
    ) external onlySafeOwner(safe) {
        if (operator == address(0)) revert ZeroAddress();

        bytes memory data = abi.encodeWithSelector(
            IERC1155.setApprovalForAll.selector,
            operator,
            approved
        );

        bool success = IGnosisSafe(safe).execTransactionFromModule(
            token,
            0,
            data,
            IGnosisSafe.Operation.Call
        );

        if (!success) revert ExecutionFailed();
    }

    // ====================  ====================

    function cancelOrderOnExchange(
        address safe,
        address exchange,
        bytes calldata data
    ) external onlyOperator nonReentrant {
        if (exchange == address(0)) revert ZeroAddress();
        require(exchange == ctfExchange, "PWM: exchange not authorized");

        bool success = IGnosisSafe(safe).execTransactionFromModule(
            exchange,
            0,
            data,
            IGnosisSafe.Operation.Call
        );

        if (!success) revert ExecutionFailed();
        emit Executed(safe, exchange, 0, data);
    }

    function executeAsOperator(
        address safe,
        address target,
        bytes calldata data
    ) external onlyOperator nonReentrant {
        if (target == address(0)) revert ZeroAddress();
        require(operatorTargets[target], "PWM: target not operator-approved");

        bool success = IGnosisSafe(safe).execTransactionFromModule(
            target,
            0,
            data,
            IGnosisSafe.Operation.Call
        );

        if (!success) revert ExecutionFailed();
        emit Executed(safe, target, 0, data);
    }

    // ====================  ====================

    function execute(
        address safe,
        address target,
        uint256 value,
        bytes calldata data
    ) external onlyOperator nonReentrant returns (bytes memory) {
        if (target == address(0)) revert ZeroAddress();
        if (!allowedTargets[safe][target]) revert TargetNotAllowed();

        bool success = IGnosisSafe(safe).execTransactionFromModule(
            target,
            value,
            data,
            IGnosisSafe.Operation.Call
        );

        if (!success) revert ExecutionFailed();
        emit Executed(safe, target, value, data);
        return "";
    }

    function batchExecute(
        address safe,
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata datas
    ) external onlyOperator nonReentrant {
        require(targets.length == values.length && values.length == datas.length, "Length mismatch");

        for (uint256 i = 0; i < targets.length; i++) {
            if (targets[i] == address(0)) revert ZeroAddress();
            if (!allowedTargets[safe][targets[i]]) revert TargetNotAllowed();

            bool success = IGnosisSafe(safe).execTransactionFromModule(
                targets[i],
                values[i],
                datas[i],
                IGnosisSafe.Operation.Call
            );

            if (!success) revert ExecutionFailed();
            emit Executed(safe, targets[i], values[i], datas[i]);
        }
    }

    // ====================  ====================

    function transferERC20ForOrder(
        address safe,
        address token,
        address to,
        uint256 amount,
        bytes32 orderHash,
        uint256 totalOrderAmount,
        uint256 expiration,
        bytes calldata signature
    ) external onlyExchange nonReentrant {
        if (token == address(0)) revert ZeroAddress();
        if (to == address(0)) revert ZeroAddress();
        require(to == msg.sender, "PWM: to must be caller");
        if (block.timestamp > expiration) revert ExpiredDeadline();

        address signer = ECDSA.recover(orderHash, signature);
        if (orderConsumed[safe][orderHash] == 0) {
            if (!IGnosisSafe(safe).isOwner(signer)) revert InvalidSignature();
            orderSigner[safe][orderHash] = signer;
            orderTotalAmount[safe][orderHash] = totalOrderAmount;
        } else {
            if (signer != orderSigner[safe][orderHash]) revert InvalidSignature();
            require(orderTotalAmount[safe][orderHash] == totalOrderAmount, "totalOrderAmount mismatch");
        }

        //
        uint256 consumed = orderConsumed[safe][orderHash];
        if (consumed + amount > totalOrderAmount) revert ExceedsOrderAmount();

        orderConsumed[safe][orderHash] = consumed + amount;

        //
        bytes memory data = abi.encodeWithSelector(IERC20.transfer.selector, to, amount);
        bool success = IGnosisSafe(safe).execTransactionFromModule(token, 0, data, IGnosisSafe.Operation.Call);
        if (!success) revert ExecutionFailed();

        emit TransferForOrder(safe, orderHash, token, to, amount);
    }

    function transferERC1155ForOrder(
        address safe,
        address token,
        address to,
        uint256 tokenId,
        uint256 amount,
        bytes32 orderHash,
        uint256 totalOrderAmount,
        uint256 expiration,
        bytes calldata signature
    ) external onlyExchange nonReentrant {
        if (token == address(0)) revert ZeroAddress();
        if (to == address(0)) revert ZeroAddress();
        require(to == msg.sender, "PWM: to must be caller");
        if (block.timestamp > expiration) revert ExpiredDeadline();

        address signer = ECDSA.recover(orderHash, signature);
        if (orderConsumed[safe][orderHash] == 0) {
            if (!IGnosisSafe(safe).isOwner(signer)) revert InvalidSignature();
            orderSigner[safe][orderHash] = signer;
            orderTotalAmount[safe][orderHash] = totalOrderAmount;
        } else {
            if (signer != orderSigner[safe][orderHash]) revert InvalidSignature();
            require(orderTotalAmount[safe][orderHash] == totalOrderAmount, "totalOrderAmount mismatch");
        }

        uint256 consumed = orderConsumed[safe][orderHash];
        if (consumed + amount > totalOrderAmount) revert ExceedsOrderAmount();

        orderConsumed[safe][orderHash] = consumed + amount;

        bytes memory data = abi.encodeWithSelector(
            IERC1155.safeTransferFrom.selector,
            safe,
            to,
            tokenId,
            amount,
            ""
        );
        bool success = IGnosisSafe(safe).execTransactionFromModule(token, 0, data, IGnosisSafe.Operation.Call);
        if (!success) revert ExecutionFailed();
    }

    function transferFeeForOrder(
        address safe,
        address token,
        address to,
        uint256 amount,
        bytes32 orderHash,
        uint256 totalOrderAmount,
        uint256 expiration,
        bytes calldata signature
    ) external onlyExchange nonReentrant {
        if (token == address(0)) revert ZeroAddress();
        if (to == address(0)) revert ZeroAddress();
        if (block.timestamp > expiration) revert ExpiredDeadline();

        address signer = ECDSA.recover(orderHash, signature);
        if (orderConsumed[safe][orderHash] == 0 && feeConsumed[safe][orderHash] == 0) {
            if (!IGnosisSafe(safe).isOwner(signer)) revert InvalidSignature();
            orderSigner[safe][orderHash] = signer;
            orderTotalAmount[safe][orderHash] = totalOrderAmount;
        } else {
            if (signer != orderSigner[safe][orderHash]) revert InvalidSignature();
            require(orderTotalAmount[safe][orderHash] == totalOrderAmount, "totalOrderAmount mismatch");
        }

        //  MAX_FEE_RATE_BPS
        feeConsumed[safe][orderHash] += amount;
        uint256 totalAmt = orderTotalAmount[safe][orderHash];
        uint256 maxFee = totalAmt == 0 ? 0 : (totalAmt * MAX_FEE_RATE_BPS + BPS_DIVISOR - 1) / BPS_DIVISOR;
        if (feeConsumed[safe][orderHash] > maxFee) revert ExceedsFeeLimit();

        bytes memory data = abi.encodeWithSelector(IERC20.transfer.selector, to, amount);
        bool success = IGnosisSafe(safe).execTransactionFromModule(token, 0, data, IGnosisSafe.Operation.Call);
        if (!success) revert ExecutionFailed();

        emit TransferForOrder(safe, orderHash, token, to, amount);
    }

    // ==================== / ====================

    function mintWithPermit(
        address safe,
        address collateralToken,
        address ctfAdapter,
        bytes32 conditionId,
        uint256 amount,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external onlyOperator nonReentrant {
        if (collateralToken == address(0)) revert ZeroAddress();
        if (ctfAdapter == address(0)) revert ZeroAddress();
        if (block.timestamp > deadline) revert ExpiredDeadline();
        if (usedNonces[safe][nonce]) revert NonceAlreadyUsed();

        //
        bytes32 structHash = keccak256(abi.encode(
            MINT_PERMIT_TYPEHASH,
            safe,
            collateralToken,
            ctfAdapter,
            conditionId,
            amount,
            nonce,
            deadline
        ));

        bytes32 digest = _hashTypedDataV4(structHash);
        address signer = ECDSA.recover(digest, signature);
        if (!IGnosisSafe(safe).isOwner(signer)) revert InvalidSignature();

        usedNonces[safe][nonce] = true;

        //
        bytes memory approveData = abi.encodeWithSelector(IERC20.approve.selector, ctfAdapter, amount);
        IGnosisSafe(safe).execTransactionFromModule(collateralToken, 0, approveData, IGnosisSafe.Operation.Call);

        //
        bytes memory depositData = abi.encodeWithSignature(
            "deposit(address,bytes32,uint256)",
            collateralToken,
            conditionId,
            amount
        );
        bool success = IGnosisSafe(safe).execTransactionFromModule(ctfAdapter, 0, depositData, IGnosisSafe.Operation.Call);
        if (!success) revert ExecutionFailed();

        emit MintWithPermit(safe, ctfAdapter, conditionId, amount);
    }

    function mergeWithPermit(
        address safe,
        address conditionalTokens,
        address ctfAdapter,
        address collateralToken,
        bytes32 conditionId,
        uint256[] calldata positionIds,
        uint256 amount,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external onlyOperator nonReentrant {
        if (conditionalTokens == address(0)) revert ZeroAddress();
        if (ctfAdapter == address(0)) revert ZeroAddress();
        if (block.timestamp > deadline) revert ExpiredDeadline();
        if (usedNonces[safe][nonce]) revert NonceAlreadyUsed();

        //
        bytes32 structHash = keccak256(abi.encode(
            MERGE_PERMIT_TYPEHASH,
            safe,
            conditionalTokens,
            ctfAdapter,
            collateralToken,
            conditionId,
            keccak256(abi.encodePacked(positionIds)),
            amount,
            nonce,
            deadline
        ));

        bytes32 digest = _hashTypedDataV4(structHash);
        address signer = ECDSA.recover(digest, signature);
        if (!IGnosisSafe(safe).isOwner(signer)) revert InvalidSignature();

        usedNonces[safe][nonce] = true;

        // 1.  CTFAdapter  ERC1155
        bytes memory setApprovalData = abi.encodeWithSignature(
            "setApprovalForAll(address,bool)",
            ctfAdapter,
            true
        );
        IGnosisSafe(safe).execTransactionFromModule(conditionalTokens, 0, setApprovalData, IGnosisSafe.Operation.Call);

        // 2.  ERC1155  CTFAdapter
        for (uint256 i = 0; i < positionIds.length; i++) {
            bytes memory transferData = abi.encodeWithSignature(
                "safeTransferFrom(address,address,uint256,uint256,bytes)",
                safe,
                ctfAdapter,
                positionIds[i],
                amount,
                ""
            );
            IGnosisSafe(safe).execTransactionFromModule(conditionalTokens, 0, transferData, IGnosisSafe.Operation.Call);
        }

        // 3. ProxyWalletModule  CTFAdapter.mergeAndReturn Safe
        //  msg.sender = ProxyWalletModule ProxyWalletModule  authorizedCallers
        ICTFAdapter(ctfAdapter).mergeAndReturn(
            IERC20(collateralToken),
            conditionId,
            amount,
            safe
        );

        emit MergeWithPermit(safe, ctfAdapter, conditionId, amount);
    }

    // ====================  ====================

    function getERC20Balance(address safe, address token) external view returns (uint256) {
        return IERC20(token).balanceOf(safe);
    }

    function getERC1155Balance(address safe, address token, uint256 tokenId) external view returns (uint256) {
        return IERC1155(token).balanceOf(safe, tokenId);
    }

    function isOperator(address account) external view returns (bool) {
        return operators[account];
    }

    function isAllowedTarget(address safe, address target) external view returns (bool) {
        return allowedTargets[safe][target];
    }
}
