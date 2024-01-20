// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import {AbstractOwnable} from "../deployer/TwoStepOwnable.sol";

import {Revert} from "../utils/Revert.sol";
import {ItoA} from "../utils/ItoA.sol";

interface IERC1967Proxy {
    event Upgraded(address indexed implementation);

    function implementation() external view returns (address);

    function version() external view returns (string memory);

    function upgrade(address newImplementation) external payable returns (bool);

    function upgradeAndCall(address newImplementation, bytes calldata data) external payable returns (bool);
}

/// The upgrade mechanism for this proxy is slightly more convoluted than the
/// previously-standard rollback-checking ERC1967 UUPS proxy. The standard
/// rollback check uses the value of the ERC1967 rollback slot to avoid infinite
/// recursion. The old implementation's `upgrade` or `upgradeAndCall` sets the
/// ERC1967 implementation slot to the new implementation, then calls `upgrade`
/// on the new implementation to attempt to set the value of the implementation
/// slot *back to the old implementation*. This is checked, and the value of the
/// implementation slot is re-set to the new implementation.
///
/// This proxy abuses the ERC1967 rollback slot to store a version number which
/// must be incremented on each upgrade. This mechanism follows the same general
/// outline as the previously-standard version. The old implementation's
/// `upgrade` or `upgradeAndCall` sets the ERC1967 implementation slot to the
/// new implementation, then calls `upgrade` on the new implementation. The new
/// implementation's `upgrade` sets the implementation slot back to the old
/// implementation *and* advances the rollback slot to the new version
/// number. The old implementation then checks the value of both the
/// implementation and rollback slots before re-setting the implementation slot
/// to the new implementation.
abstract contract ERC1967UUPSUpgradeable is AbstractOwnable, IERC1967Proxy {
    error OnlyProxy();
    error AlreadyInitialized();
    error InterferedWithImplementation(address expected, address actual);
    error InterferedWithVersion(uint256 expected, uint256 actual);
    error DidNotIncrementVersion(uint256 current, uint256 next);
    error RollbackFailed(address expected, address actual);
    error InitializationFailed();

    using Revert for bytes;

    address internal immutable _implementation;
    uint256 internal immutable _implVersion;

    uint256 private constant _IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    uint256 private constant _ROLLBACK_SLOT = 0x4910fdfa16fed3260ed0e7147f7cc6da11a60208b5b9406d12a635614ffd9143;

    constructor(uint256 newVersion) {
        assert(_IMPLEMENTATION_SLOT == uint256(keccak256("eip1967.proxy.implementation")) - 1);
        assert(_ROLLBACK_SLOT == uint256(keccak256("eip1967.proxy.rollback")) - 1);
        _implementation = address(this);
        require(newVersion != 0);
        _implVersion = newVersion;
    }

    function implementation() public view virtual override returns (address result) {
        assembly ("memory-safe") {
            result := sload(_IMPLEMENTATION_SLOT)
        }
    }

    function version() public view virtual override returns (string memory) {
        return ItoA.itoa(_storageVersion());
    }

    function _setImplementation(address newImplementation) private {
        assembly ("memory-safe") {
            sstore(_IMPLEMENTATION_SLOT, newImplementation)
        }
    }

    function _storageVersion() private view returns (uint256 result) {
        assembly ("memory-safe") {
            result := sload(_ROLLBACK_SLOT)
        }
    }

    function _setVersion(uint256 newVersion) private {
        assembly ("memory-safe") {
            sstore(_ROLLBACK_SLOT, newVersion)
        }
    }

    function _requireProxy() private view returns (address impl) {
        impl = _implementation;
        if (implementation() != impl || address(this) == impl) {
            revert OnlyProxy();
        }
    }

    modifier onlyProxy() {
        _requireProxy();
        _;
    }

    function supportsInterface(bytes4 interfaceId) public view virtual override onlyProxy returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    // This makes `onlyOwner` imply `onlyProxy`
    function owner() public view virtual override onlyProxy returns (address) {
        return super.owner();
    }

    function _initialize() internal virtual {
        address impl = _requireProxy();

        assert(_implVersion == 1);

        if (_storageVersion() != 0) {
            revert AlreadyInitialized();
        }
        _setVersion(1);
        emit Upgraded(impl);
    }

    // This hook exists for schemes that append authenticated metadata to calldata
    // (e.g. ERC2771). If msg.sender during the upgrade call is the authenticator,
    // the metadata must be copied from the outer calldata into the delegatecall
    // calldata to ensure that any logic in the new implementation that inspects
    // msg.sender and decodes the authenticated metadata gets the correct result.
    function _encodeDelegateCall(bytes memory callData) internal view virtual returns (bytes memory) {
        return callData;
    }

    function _delegateCall(address impl, bytes memory data, bytes memory err) private returns (bytes memory) {
        (bool success, bytes memory returnData) = impl.delegatecall(_encodeDelegateCall(data));
        if (!success) {
            if (returnData.length > 0) {
                returnData._revert();
            } else {
                err._revert();
            }
        }
        return returnData;
    }

    function _checkRollback(address newImplementation) private {
        if (_storageVersion() < _implVersion) {
            _setVersion(_implVersion);
        } else {
            _delegateCall(
                newImplementation,
                abi.encodeCall(IERC1967Proxy.upgrade, (_implementation)),
                abi.encodeWithSelector(RollbackFailed.selector, _implementation, newImplementation)
            );
            if (implementation() != _implementation) {
                revert RollbackFailed(_implementation, implementation());
            }
            if (_storageVersion() <= _implVersion) {
                revert DidNotIncrementVersion(_implVersion, _storageVersion());
            }
            _setImplementation(newImplementation);
            emit Upgraded(newImplementation);
        }
    }

    /// @notice attempting to upgrade to a new implementation with a version
    ///         number that does not increase will result in infinite recursion
    ///         and a revert
    function upgrade(address newImplementation) public payable virtual override onlyOwner returns (bool) {
        _setImplementation(newImplementation);
        _checkRollback(newImplementation);
        return true;
    }

    /// @notice attempting to upgrade to a new implementation with a version
    ///         number that does not increase will result in infinite recursion
    ///         and a revert
    function upgradeAndCall(address newImplementation, bytes calldata data)
        public
        payable
        virtual
        override
        onlyOwner
        returns (bool)
    {
        _setImplementation(newImplementation);
        _delegateCall(newImplementation, data, abi.encodeWithSelector(InitializationFailed.selector));
        if (implementation() != newImplementation) {
            revert InterferedWithImplementation(newImplementation, implementation());
        }
        if (_storageVersion() > _implVersion) {
            revert InterferedWithVersion(_implVersion, _storageVersion());
        }
        _checkRollback(newImplementation);
        return true;
    }
}
