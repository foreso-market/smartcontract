// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/access/Ownable.sol";

interface IGnosisSafeProxyFactory {
    function createProxyWithNonce(
        address _singleton,
        bytes memory initializer,
        uint256 saltNonce
    ) external returns (address proxy);

    function proxyCreationCode() external pure returns (bytes memory);
}

interface IGnosisSafe {
    function setup(
        address[] calldata _owners,
        uint256 _threshold,
        address to,
        bytes calldata data,
        address fallbackHandler,
        address paymentToken,
        uint256 payment,
        address payable paymentReceiver
    ) external;

    function enableModule(address module) external;

    function isModuleEnabled(address module) external view returns (bool);

    function getOwners() external view returns (address[] memory);
}

contract SafeProxyWalletFactory is Ownable {

    address private immutable _self;

    address public immutable safeProxyFactory;

    address public safeSingleton;

    address public proxyWalletModule;

    address public fallbackHandler;

    address[] public defaultOperators;

    address[] public presetAllowedTargets;

    mapping(address => address) public proxyWallets;

    event ProxyWalletCreated(address indexed masterWallet, address indexed proxyWallet);
    event DefaultOperatorsUpdated(address[] operators);
    event PresetAllowedTargetsUpdated(address[] targets);
    event SafeSingletonUpdated(address indexed oldSingleton, address indexed newSingleton);
    event ModuleUpdated(address indexed oldModule, address indexed newModule);

    error ProxyWalletAlreadyExists();
    error ProxyWalletNotFound();
    error ZeroAddress();
    error ProxyDeploymentFailed();

    constructor(
        address _safeProxyFactory,
        address _safeSingleton,
        address _proxyWalletModule,
        address _fallbackHandler,
        address[] memory _defaultOperators
    ) Ownable(msg.sender) {
        require(_safeProxyFactory != address(0), "Invalid SafeProxyFactory");
        require(_safeSingleton != address(0), "Invalid SafeSingleton");
        require(_proxyWalletModule != address(0), "Invalid Module");
        require(_defaultOperators.length > 0, "At least one operator required");

        _self = address(this);
        safeProxyFactory = _safeProxyFactory;
        safeSingleton = _safeSingleton;
        proxyWalletModule = _proxyWalletModule;
        fallbackHandler = _fallbackHandler;
        defaultOperators = _defaultOperators;
    }

    function createProxyWallet(address masterWallet)
        external
        returns (address proxyWallet)
    {
        if (masterWallet == address(0)) revert ZeroAddress();
        if (proxyWallets[masterWallet] != address(0)) revert ProxyWalletAlreadyExists();

        //  Safe
        address[] memory owners = new address[](1);
        owners[0] = masterWallet;

        //  enableModule
        bytes memory enableModuleData = abi.encodeWithSelector(
            this.setupModule.selector,
            proxyWalletModule,
            presetAllowedTargets
        );

        //  setup  setup  Module
        bytes memory initializer = abi.encodeWithSelector(
            IGnosisSafe.setup.selector,
            owners,           // owners
            1,                // threshold
            address(this),    // to -  setupModule
            enableModuleData, // data - enableModule
            fallbackHandler,  // fallbackHandler
            address(0),       // paymentToken
            0,                // payment
            address(0)        // paymentReceiver
        );

        //  masterWallet  salt
        uint256 saltNonce = uint256(uint160(masterWallet));

        //  Safe
        proxyWallet = IGnosisSafeProxyFactory(safeProxyFactory).createProxyWithNonce(
            safeSingleton,
            initializer,
            saltNonce
        );

        if (proxyWallet == address(0)) revert ProxyDeploymentFailed();

        //
        proxyWallets[masterWallet] = proxyWallet;

        emit ProxyWalletCreated(masterWallet, proxyWallet);
    }

    function setupModule(address module, address[] calldata targets) external {
        // ⚠️  delegatecall
        //  delegatecall address(this) Safe Factory
        // address(this) == _selfFactory
        require(address(this) != _self, "Direct call not allowed");

        // Safe ModuleManager  SENTINEL_MODULES
        address SENTINEL = address(0x1);

        //  Safe  modules slot 1
        //  delegatecall address(this)  Safe
        // modules  slot 1: mapping(address => address) modules

        // 1. modules[SENTINEL] = module module
        assembly {
            // modules mapping  slot 1
            // key = SENTINEL (0x1)
            // slot = keccak256(key . 1)
            mstore(0x00, SENTINEL)
            mstore(0x20, 1)
            let slot := keccak256(0x00, 0x40)
            sstore(slot, module)
        }

        // 2. modules[module] = SENTINEL module  SENTINEL
        assembly {
            mstore(0x00, module)
            mstore(0x20, 1)
            let slot := keccak256(0x00, 0x40)
            sstore(slot, SENTINEL)
        }

        // targets
        targets;
    }

    function computeProxyAddress(address masterWallet)
        public
        view
        returns (address)
    {
        if (masterWallet == address(0)) revert ZeroAddress();

        //
        address[] memory owners = new address[](1);
        owners[0] = masterWallet;

        bytes memory initializer = abi.encodeWithSelector(
            IGnosisSafe.setup.selector,
            owners,
            1,
            address(this),
            abi.encodeWithSelector(this.setupModule.selector, proxyWalletModule, presetAllowedTargets),
            fallbackHandler,
            address(0),
            0,
            address(0)
        );

        uint256 saltNonce = uint256(uint160(masterWallet));

        //  CREATE2
        bytes32 salt = keccak256(abi.encodePacked(keccak256(initializer), saltNonce));

        bytes memory deploymentData = abi.encodePacked(
            IGnosisSafeProxyFactory(safeProxyFactory).proxyCreationCode(),
            uint256(uint160(safeSingleton))
        );

        bytes32 hash = keccak256(
            abi.encodePacked(
                bytes1(0xff),
                safeProxyFactory,
                salt,
                keccak256(deploymentData)
            )
        );

        return address(uint160(uint256(hash)));
    }

    function getProxyWallet(address masterWallet)
        external
        view
        returns (address)
    {
        address proxyWallet = proxyWallets[masterWallet];
        if (proxyWallet == address(0)) revert ProxyWalletNotFound();
        return proxyWallet;
    }

    function proxyWalletExists(address masterWallet)
        external
        view
        returns (bool)
    {
        return proxyWallets[masterWallet] != address(0);
    }

    // ====================  ====================

    function updateSafeSingleton(address newSingleton) external onlyOwner {
        require(newSingleton != address(0), "Invalid singleton");
        address oldSingleton = safeSingleton;
        safeSingleton = newSingleton;
        emit SafeSingletonUpdated(oldSingleton, newSingleton);
    }

    function updateProxyWalletModule(address newModule) external onlyOwner {
        require(newModule != address(0), "Invalid module");
        address oldModule = proxyWalletModule;
        proxyWalletModule = newModule;
        emit ModuleUpdated(oldModule, newModule);
    }

    function getImplementation() external view returns (address) {
        return safeSingleton;
    }

    function getModule() external view returns (address) {
        return proxyWalletModule;
    }

    // ====================  ====================

    function updateDefaultOperators(address[] calldata newOperators) external onlyOwner {
        require(newOperators.length > 0, "At least one operator required");
        delete defaultOperators;
        for (uint256 i = 0; i < newOperators.length; i++) {
            if (newOperators[i] != address(0)) {
                defaultOperators.push(newOperators[i]);
            }
        }
        emit DefaultOperatorsUpdated(defaultOperators);
    }

    function getDefaultOperators() external view returns (address[] memory) {
        return defaultOperators;
    }

    function setPresetAllowedTargets(address[] calldata targets) external onlyOwner {
        delete presetAllowedTargets;
        for (uint256 i = 0; i < targets.length; i++) {
            if (targets[i] != address(0)) {
                presetAllowedTargets.push(targets[i]);
            }
        }
        emit PresetAllowedTargetsUpdated(presetAllowedTargets);
    }

    function getPresetAllowedTargets() external view returns (address[] memory) {
        return presetAllowedTargets;
    }

    function addPresetAllowedTarget(address target) external onlyOwner {
        if (target == address(0)) revert ZeroAddress();
        for (uint256 i = 0; i < presetAllowedTargets.length; i++) {
            if (presetAllowedTargets[i] == target) return;
        }
        presetAllowedTargets.push(target);
        emit PresetAllowedTargetsUpdated(presetAllowedTargets);
    }

    function removePresetAllowedTarget(address target) external onlyOwner {
        for (uint256 i = 0; i < presetAllowedTargets.length; i++) {
            if (presetAllowedTargets[i] == target) {
                presetAllowedTargets[i] = presetAllowedTargets[presetAllowedTargets.length - 1];
                presetAllowedTargets.pop();
                emit PresetAllowedTargetsUpdated(presetAllowedTargets);
                return;
            }
        }
    }
}
