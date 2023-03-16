// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {Permit2} from "permit2/src/Permit2.sol";
import {ISignatureTransfer} from "permit2/src/interfaces/ISignatureTransfer.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

abstract contract Permit2Payment {
    /// @dev Permit2 address
    Permit2 private immutable PERMIT2;

    constructor(address permit2) {
        PERMIT2 = Permit2(permit2);
    }

    function permit2TransferFrom(
        ISignatureTransfer.PermitTransferFrom memory permit,
        ISignatureTransfer.SignatureTransferDetails memory transferDetails,
        address from,
        bytes memory sig
    ) internal {
        PERMIT2.permitTransferFrom(permit, transferDetails, from, sig);
    }
}
