// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {ISignatureTransfer} from "permit2/src/interfaces/ISignatureTransfer.sol";

import {BasePairTest} from "./BasePairTest.t.sol";
import {ICurveV2Pool} from "./vendor/ICurveV2Pool.sol";
import {IZeroEx} from "./vendor/IZeroEx.sol";

import {LibBytes} from "../utils/LibBytes.sol";
import {ActionDataBuilder} from "../utils/ActionDataBuilder.sol";

import {SafeTransferLib} from "../../src/utils/SafeTransferLib.sol";

import {Settler} from "../../src/Settler.sol";
import {ISettlerActions} from "../../src/ISettlerActions.sol";
import {OtcOrderSettlement} from "../../src/core/OtcOrderSettlement.sol";

abstract contract SettlerPairTest is BasePairTest {
    using SafeTransferLib for ERC20;
    using LibBytes for bytes;

    uint256 private PERMIT2_FROM_NONCE = 1;
    uint256 private PERMIT2_MAKER_NONCE = 1;

    Settler private settler;
    IZeroEx private ZERO_EX = IZeroEx(0xDef1C0ded9bec7F1a1670819833240f027b25EfF);

    // 0x V4 OTCOrder
    IZeroEx.OtcOrder private otcOrder;
    bytes32 private otcOrderHash;

    function setUp() public virtual override {
        super.setUp();
        settler = getSettler();
        safeApproveIfBelow(fromToken(), FROM, address(PERMIT2), amount());
        // Otc via ZeroEx
        safeApproveIfBelow(toToken(), MAKER, address(ZERO_EX), amount());
        // Otc inside of Settler
        safeApproveIfBelow(toToken(), MAKER, address(PERMIT2), amount());

        // First time inits for Settler
        // We set up allowances to contracts which are inited on the first trade for a fair comparison
        // e.g to a Curve Pool
        ICurveV2Pool.CurveV2PoolData memory poolData = getCurveV2PoolData();
        safeApproveIfBelow(fromToken(), address(settler), address(poolData.pool), amount());
        // ZeroEx for Settler using ZeroEx OTC
        safeApproveIfBelow(fromToken(), address(settler), address(ZERO_EX), amount());

        // Otc 0x v4 order
        otcOrder.makerToken = toToken();
        otcOrder.takerToken = fromToken();
        otcOrder.makerAmount = uint128(amount());
        otcOrder.takerAmount = uint128(amount());
        otcOrder.taker = address(0);
        otcOrder.txOrigin = FROM;
        otcOrder.expiryAndNonce = type(uint256).max;
        otcOrder.maker = MAKER;
        otcOrderHash = ZERO_EX.getOtcOrderHash(otcOrder);

        warmPermit2Nonce(FROM);
        warmPermit2Nonce(MAKER);
    }

    function uniswapV3Path() internal virtual returns (bytes memory);
    function getCurveV2PoolData() internal pure virtual returns (ICurveV2Pool.CurveV2PoolData memory);

    function getSettler() private returns (Settler settler) {
        settler = new Settler(
            address(PERMIT2), 
            address(ZERO_EX), // ZeroEx
            0x1F98431c8aD98523631AE4a59f267346ea31F984, // UniV3 Factory
            0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54 // UniV3 pool init code hash
        );
    }

    function testSettler_zeroExOtcOrder() public {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(MAKER_PRIVATE_KEY, otcOrderHash);

        // TODO can use safer encodeCall
        bytes[] memory actions = new bytes[](2);
        actions[0] = _getDefaultFromPermit2Action();
        actions[1] = abi.encodeWithSelector(
            ISettlerActions.ZERO_EX_OTC.selector,
            otcOrder,
            IZeroEx.Signature(IZeroEx.SignatureType.EIP712, v, r, s),
            amount()
        );

        Settler _settler = settler;
        vm.startPrank(FROM, FROM);
        snapStartName("settler_zeroExOtc");
        _settler.execute(actions);
        snapEnd();
    }

    function testSettler_uniswapV3VIP() public {
        bytes[] memory actions = ActionDataBuilder.build(
            abi.encodeCall(
                ISettlerActions.UNISWAPV3_PERMIT2_SWAP_EXACT_IN,
                (FROM, amount(), 1, uniswapV3Path(), _getDefaultFromPermit2Action().popSelector())
            )
        );

        Settler _settler = settler;
        vm.startPrank(FROM);
        snapStartName("settler_uniswapV3VIP");
        _settler.execute(actions);
        snapEnd();
    }

    function testSettler_uniswapV3_multiplex2() public {
        bytes[] memory actions = ActionDataBuilder.build(
            _getDefaultFromPermit2Action(),
            abi.encodeCall(ISettlerActions.UNISWAPV3_SWAP_EXACT_IN, (FROM, amount() / 2, 1, uniswapV3Path())),
            abi.encodeCall(ISettlerActions.UNISWAPV3_SWAP_EXACT_IN, (FROM, amount() / 2, 1, uniswapV3Path()))
        );

        Settler _settler = settler;
        vm.startPrank(FROM);
        snapStartName("settler_uniswapV3_multiplex2");
        _settler.execute(actions);
        snapEnd();
    }

    function testSettler_uniswapV3() public {
        bytes[] memory actions = ActionDataBuilder.build(
            _getDefaultFromPermit2Action(),
            abi.encodeCall(ISettlerActions.UNISWAPV3_SWAP_EXACT_IN, (FROM, amount(), 1, uniswapV3Path()))
        );

        Settler _settler = settler;
        vm.startPrank(FROM);
        snapStartName("settler_uniswapV3");
        _settler.execute(actions);
        snapEnd();
    }

    function testSettler_uniswapV3_fee_full_custody() public {
        bytes[] memory actions = ActionDataBuilder.build(
            _getDefaultFromPermit2Action(),
            abi.encodeCall(ISettlerActions.UNISWAPV3_SWAP_EXACT_IN, (address(settler), amount(), 1, uniswapV3Path())),
            abi.encodeCall(ISettlerActions.TRANSFER_OUT, (address(toToken()), BURN_ADDRESS, 1_000)),
            abi.encodeCall(ISettlerActions.TRANSFER_OUT, (address(toToken()), FROM, 10_000))
        );

        snapStartName("settler_uniswapV3_buyToken_fee_full_custody");
        vm.startPrank(FROM);
        settler.execute(actions);
        snapEnd();
    }

    function testSettler_uniswapV3_buyToken_fee_single_custody() public {
        bytes[] memory actions = ActionDataBuilder.build(
            abi.encodeCall(
                ISettlerActions.UNISWAPV3_PERMIT2_SWAP_EXACT_IN,
                (address(settler), amount(), 1, uniswapV3Path(), _getDefaultFromPermit2Action().popSelector())
            ),
            abi.encodeCall(ISettlerActions.TRANSFER_OUT, (address(toToken()), BURN_ADDRESS, 1_000)),
            abi.encodeCall(ISettlerActions.TRANSFER_OUT, (address(toToken()), FROM, 10_000))
        );

        Settler _settler = settler;
        vm.startPrank(FROM);
        snapStartName("settler_uniswapV3_buyToken_fee_single_custody");
        _settler.execute(actions);
        snapEnd();
    }

    function testSettler_uniswapV3_sellToken_fee_single_custody() public {
        ISignatureTransfer.PermitBatchTransferFrom memory permit = ISignatureTransfer.PermitBatchTransferFrom({
            permitted: new ISignatureTransfer.TokenPermissions[](2),
            nonce: PERMIT2_FROM_NONCE,
            deadline: block.timestamp + 100
        });
        permit.permitted[0] = ISignatureTransfer.TokenPermissions({token: address(fromToken()), amount: amount() - 1});
        permit.permitted[1] = ISignatureTransfer.TokenPermissions({token: address(fromToken()), amount: 1});

        bytes memory sig =
            getPermitBatchTransferSignature(permit, address(settler), FROM_PRIVATE_KEY, PERMIT2.DOMAIN_SEPARATOR());

        bytes[] memory actions = ActionDataBuilder.build(
            abi.encodeCall(ISettlerActions.PERMIT2_BATCH_TRANSFER_FROM, (permit, sig)),
            abi.encodeCall(ISettlerActions.UNISWAPV3_SWAP_EXACT_IN, (FROM, amount() - 1, 1, uniswapV3Path()))
        );

        snapStartName("settler_uniswapV3_sellToken_fee_single_custody");
        vm.startPrank(FROM);
        settler.execute(actions);
        snapEnd();
    }

    function testSettler_uniswapV3VIP_sellToken_fee() public {
        ISignatureTransfer.PermitBatchTransferFrom memory permit = ISignatureTransfer.PermitBatchTransferFrom({
            permitted: new ISignatureTransfer.TokenPermissions[](2),
            nonce: PERMIT2_FROM_NONCE,
            deadline: block.timestamp + 100
        });
        permit.permitted[0] = ISignatureTransfer.TokenPermissions({token: address(fromToken()), amount: amount() - 1});
        permit.permitted[1] = ISignatureTransfer.TokenPermissions({token: address(fromToken()), amount: 1});

        bytes memory sig =
            getPermitBatchTransferSignature(permit, address(settler), FROM_PRIVATE_KEY, PERMIT2.DOMAIN_SEPARATOR());
        bytes[] memory actions = ActionDataBuilder.build(
            abi.encodeCall(
                ISettlerActions.UNISWAPV3_PERMIT2_SWAP_EXACT_IN,
                (FROM, amount() - 1, 1, uniswapV3Path(), abi.encode(permit, sig))
            )
        );

        Settler _settler = settler;
        vm.startPrank(FROM);
        snapStartName("settler_uniswapV3VIP_sellToken_fee");
        _settler.execute(actions);
        snapEnd();
    }

    function testSettler_curveV2VIP() public skipIf(getCurveV2PoolData().pool == address(0)) {
        ICurveV2Pool.CurveV2PoolData memory poolData = getCurveV2PoolData();

        bytes[] memory actions = ActionDataBuilder.build(
            _getDefaultFromPermit2Action(),
            abi.encodeCall(
                ISettlerActions.CURVE_UINT256_EXCHANGE,
                (
                    address(poolData.pool),
                    address(fromToken()),
                    poolData.fromTokenIndex,
                    poolData.toTokenIndex,
                    amount(),
                    1
                )
            ),
            abi.encodeCall(ISettlerActions.TRANSFER_OUT, (address(toToken()), FROM, 10_000))
        );

        Settler _settler = settler;
        vm.startPrank(FROM);
        snapStartName("settler_curveV2VIP");
        _settler.execute(actions);
        snapEnd();
    }

    function testSettler_curveV2_fee() public skipIf(getCurveV2PoolData().pool == address(0)) {
        ICurveV2Pool.CurveV2PoolData memory poolData = getCurveV2PoolData();

        bytes[] memory actions = ActionDataBuilder.build(
            _getDefaultFromPermit2Action(),
            abi.encodeCall(
                ISettlerActions.CURVE_UINT256_EXCHANGE,
                (
                    address(poolData.pool),
                    address(fromToken()),
                    poolData.fromTokenIndex,
                    poolData.toTokenIndex,
                    amount(),
                    1
                )
            ),
            abi.encodeCall(ISettlerActions.TRANSFER_OUT, (address(toToken()), BURN_ADDRESS, 1_000)),
            abi.encodeCall(ISettlerActions.TRANSFER_OUT, (address(toToken()), FROM, 10_000))
        );

        Settler _settler = settler;
        vm.startPrank(FROM);
        snapStartName("settler_curveV2_fee");
        _settler.execute(actions);
        snapEnd();
    }

    bytes32 private constant OTC_PERMIT2_WITNESS_TYPEHASH = keccak256(
        "PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,OtcOrder order)OtcOrder(address makerToken,address takerToken,uint128 makerAmount,uint128 takerAmount,address maker,address taker,address txOrigin)TokenPermissions(address token,uint256 amount)"
    );

    bytes32 private constant OTC_PERMIT2_BATCH_WITNESS_TYPEHASH = keccak256(
        "PermitBatchWitnessTransferFrom(TokenPermissions[] permitted,address spender,uint256 nonce,uint256 deadline,OtcOrder order)OtcOrder(address makerToken,address takerToken,uint128 makerAmount,uint128 takerAmount,address maker,address taker,address txOrigin)TokenPermissions(address token,uint256 amount)"
    );

    /// @dev Performs an direct OTC trade between MAKER and FROM
    // Funds are transferred MAKER->FROM and FROM->MAKER
    function testSettler_otc() public {
        ISignatureTransfer.PermitTransferFrom memory makerPermit =
            defaultERC20PermitTransfer(address(toToken()), uint160(amount()), PERMIT2_MAKER_NONCE);
        ISignatureTransfer.PermitTransferFrom memory takerPermit =
            defaultERC20PermitTransfer(address(fromToken()), uint160(amount()), PERMIT2_FROM_NONCE);

        OtcOrderSettlement.OtcOrder memory order = OtcOrderSettlement.OtcOrder({
            makerToken: address(toToken()),
            takerToken: address(fromToken()),
            makerAmount: uint128(amount()),
            takerAmount: uint128(amount()),
            maker: MAKER,
            taker: address(0),
            txOrigin: FROM
        });
        bytes32 witness = keccak256(abi.encode(order));
        bytes memory makerSig = getPermitWitnessTransferSignature(
            makerPermit,
            address(settler),
            MAKER_PRIVATE_KEY,
            OTC_PERMIT2_WITNESS_TYPEHASH,
            witness,
            PERMIT2.DOMAIN_SEPARATOR()
        );

        bytes memory takerSig =
            getPermitTransferSignature(takerPermit, address(settler), FROM_PRIVATE_KEY, PERMIT2.DOMAIN_SEPARATOR());

        bytes[] memory actions = ActionDataBuilder.build(
            abi.encodeCall(
                ISettlerActions.SETTLER_OTC,
                (order, makerPermit, makerSig, takerPermit, takerSig, uint128(amount()), FROM)
            )
        );

        Settler _settler = settler;
        vm.startPrank(FROM, FROM);
        snapStartName("settler_otc");
        _settler.execute(actions);
        snapEnd();
    }

    /// @dev Performs an direct OTC trade between MAKER and FROM including fees
    // Funds are transferred MAKER->FROM, MAKER->FEE_RECIPIENT and FROM->MAKER
    function testSettler_otc_buyToken_fee() public {
        ISignatureTransfer.PermitBatchTransferFrom memory makerPermit = ISignatureTransfer.PermitBatchTransferFrom({
            permitted: new ISignatureTransfer.TokenPermissions[](2),
            nonce: PERMIT2_MAKER_NONCE,
            deadline: block.timestamp + 100
        });
        makerPermit.permitted[0] =
            ISignatureTransfer.TokenPermissions({token: address(toToken()), amount: amount() - 1});
        makerPermit.permitted[1] = ISignatureTransfer.TokenPermissions({token: address(toToken()), amount: 1});

        ISignatureTransfer.PermitBatchTransferFrom memory takerPermit = ISignatureTransfer.PermitBatchTransferFrom({
            permitted: new ISignatureTransfer.TokenPermissions[](1),
            nonce: PERMIT2_FROM_NONCE,
            deadline: block.timestamp + 100
        });
        takerPermit.permitted[0] = ISignatureTransfer.TokenPermissions({token: address(fromToken()), amount: amount()});

        OtcOrderSettlement.OtcOrder memory order = OtcOrderSettlement.OtcOrder({
            makerToken: address(toToken()),
            takerToken: address(fromToken()),
            makerAmount: uint128(amount()),
            takerAmount: uint128(amount()),
            maker: MAKER,
            taker: address(0),
            txOrigin: FROM
        });
        bytes32 witness = keccak256(abi.encode(order));
        bytes memory makerSig = getPermitBatchWitnessTransferSignature(
            makerPermit,
            address(settler),
            MAKER_PRIVATE_KEY,
            OTC_PERMIT2_BATCH_WITNESS_TYPEHASH,
            witness,
            PERMIT2.DOMAIN_SEPARATOR()
        );

        bytes memory takerSig =
            getPermitBatchTransferSignature(takerPermit, address(settler), FROM_PRIVATE_KEY, PERMIT2.DOMAIN_SEPARATOR());

        bytes[] memory actions = ActionDataBuilder.build(
            abi.encodeCall(
                ISettlerActions.SETTLER_OTC_BATCH_PERMIT2,
                (order, makerPermit, makerSig, takerPermit, takerSig, uint128(amount()), FROM)
            )
        );

        Settler _settler = settler;
        vm.startPrank(FROM, FROM);
        snapStartName("settler_otc_buyToken_fee");
        _settler.execute(actions);
        snapEnd();
    }

    /// @dev Performs an direct OTC trade between MAKER and FROM including fees
    // Funds are transferred MAKER->FROM, FROM->MAKER and FROM->FEE_RECIPIENT
    function testSettler_otc_sellToken_fee() public {
        ISignatureTransfer.PermitBatchTransferFrom memory makerPermit = ISignatureTransfer.PermitBatchTransferFrom({
            permitted: new ISignatureTransfer.TokenPermissions[](1),
            nonce: PERMIT2_MAKER_NONCE,
            deadline: block.timestamp + 100
        });
        makerPermit.permitted[0] = ISignatureTransfer.TokenPermissions({token: address(toToken()), amount: amount()});

        ISignatureTransfer.PermitBatchTransferFrom memory takerPermit = ISignatureTransfer.PermitBatchTransferFrom({
            permitted: new ISignatureTransfer.TokenPermissions[](2),
            nonce: PERMIT2_FROM_NONCE,
            deadline: block.timestamp + 100
        });
        takerPermit.permitted[0] =
            ISignatureTransfer.TokenPermissions({token: address(fromToken()), amount: amount() - 1});
        takerPermit.permitted[1] = ISignatureTransfer.TokenPermissions({token: address(fromToken()), amount: 1});

        OtcOrderSettlement.OtcOrder memory order = OtcOrderSettlement.OtcOrder({
            makerToken: address(toToken()),
            takerToken: address(fromToken()),
            makerAmount: uint128(amount()),
            takerAmount: uint128(amount() - 1),
            maker: MAKER,
            taker: address(0),
            txOrigin: FROM
        });
        bytes32 witness = keccak256(abi.encode(order));
        bytes memory makerSig = getPermitBatchWitnessTransferSignature(
            makerPermit,
            address(settler),
            MAKER_PRIVATE_KEY,
            OTC_PERMIT2_BATCH_WITNESS_TYPEHASH,
            witness,
            PERMIT2.DOMAIN_SEPARATOR()
        );

        bytes memory takerSig =
            getPermitBatchTransferSignature(takerPermit, address(settler), FROM_PRIVATE_KEY, PERMIT2.DOMAIN_SEPARATOR());

        bytes[] memory actions = ActionDataBuilder.build(
            abi.encodeCall(
                ISettlerActions.SETTLER_OTC_BATCH_PERMIT2,
                (order, makerPermit, makerSig, takerPermit, takerSig, uint128(amount()), FROM)
            )
        );

        Settler _settler = settler;
        vm.startPrank(FROM, FROM);
        snapStartName("settler_otc_sellToken_fee");
        _settler.execute(actions);
        snapEnd();
    }

    bytes32 private constant FULL_PERMIT2_WITNESS_TYPEHASH = keccak256(
        "PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,bytes[] actions)TokenPermissions(address token,uint256 amount)"
    );

    function testSettler_metaTxn_uniswapV3() public {
        ISignatureTransfer.PermitTransferFrom memory permit =
            defaultERC20PermitTransfer(address(fromToken()), uint160(amount()), PERMIT2_FROM_NONCE);

        bytes[] memory actions = ActionDataBuilder.build(
            abi.encodeCall(ISettlerActions.METATXN_PERMIT2_WITNESS_TRANSFER_FROM, (permit, FROM)),
            abi.encodeCall(ISettlerActions.UNISWAPV3_SWAP_EXACT_IN, (FROM, amount(), 1, uniswapV3Path()))
        );

        bytes32 witness = keccak256(abi.encode(actions));
        bytes memory sig = getPermitWitnessTransferSignature(
            permit,
            address(settler),
            FROM_PRIVATE_KEY,
            FULL_PERMIT2_WITNESS_TYPEHASH,
            witness,
            PERMIT2.DOMAIN_SEPARATOR()
        );

        Settler _settler = settler;
        // Submitted by third party
        vm.startPrank(address(this), address(this)); // does a `call` to keep the optimizer from reordering opcodes
        snapStartName("settler_metaTxn_uniswapV3");
        _settler.executeMetaTxn(actions, sig);
        snapEnd();
    }

    function testSettler_metaTxn_otc() public {
        ISignatureTransfer.PermitTransferFrom memory makerPermit =
            defaultERC20PermitTransfer(address(toToken()), uint160(amount()), PERMIT2_MAKER_NONCE);
        ISignatureTransfer.PermitTransferFrom memory takerPermit =
            defaultERC20PermitTransfer(address(fromToken()), uint160(amount()), PERMIT2_FROM_NONCE);

        OtcOrderSettlement.OtcOrder memory order = OtcOrderSettlement.OtcOrder({
            makerToken: address(toToken()),
            takerToken: address(fromToken()),
            makerAmount: uint128(amount()),
            takerAmount: uint128(amount()),
            maker: MAKER,
            taker: FROM,
            txOrigin: address(0)
        });
        bytes32 witness = keccak256(abi.encode(order));
        bytes memory makerSig = getPermitWitnessTransferSignature(
            makerPermit,
            address(settler),
            MAKER_PRIVATE_KEY,
            OTC_PERMIT2_WITNESS_TYPEHASH,
            witness,
            PERMIT2.DOMAIN_SEPARATOR()
        );
        bytes memory takerSig = getPermitWitnessTransferSignature(
            takerPermit,
            address(settler),
            FROM_PRIVATE_KEY,
            OTC_PERMIT2_WITNESS_TYPEHASH,
            witness,
            PERMIT2.DOMAIN_SEPARATOR()
        );

        bytes[] memory actions = ActionDataBuilder.build(
            abi.encodeCall(ISettlerActions.METATXN_SETTLER_OTC, (order, makerPermit, makerSig, takerPermit, takerSig))
        );

        Settler _settler = settler;
        // Submitted by third party
        vm.startPrank(address(this), address(this)); // does a `call` to keep the optimizer from reordering opcodes
        snapStartName("settler_metaTxn_otc");
        _settler.executeMetaTxn(actions, new bytes(0));
        snapEnd();
    }

    /// @dev Performs a direct OTC trade between MAKER and FROM but with Settler receiving the sell and buy token funds.
    /// Funds transfer
    ///   OTC
    ///     TAKER->Settler
    ///     MAKER->Settler
    ///     Settler->MAKER
    ///   TRANSFER_OUT
    ///     Settler->FEE_RECIPIENT
    ///     Settler->FROM
    function testSettler_otc_fee_full_custody() public {
        ISignatureTransfer.PermitTransferFrom memory makerPermit =
            defaultERC20PermitTransfer(address(toToken()), uint160(amount()), PERMIT2_MAKER_NONCE);

        OtcOrderSettlement.OtcOrder memory order = OtcOrderSettlement.OtcOrder({
            makerToken: address(toToken()),
            takerToken: address(fromToken()),
            makerAmount: uint128(amount()),
            takerAmount: uint128(amount()),
            maker: MAKER,
            taker: address(0),
            txOrigin: FROM
        });
        bytes32 witness = keccak256(abi.encode(order));
        bytes memory makerSig = getPermitWitnessTransferSignature(
            makerPermit,
            address(settler),
            MAKER_PRIVATE_KEY,
            OTC_PERMIT2_WITNESS_TYPEHASH,
            witness,
            PERMIT2.DOMAIN_SEPARATOR()
        );

        bytes[] memory actions = ActionDataBuilder.build(
            _getDefaultFromPermit2Action(),
            abi.encodeCall(ISettlerActions.SETTLER_OTC_SELF_FUNDED, (order, makerPermit, makerSig, uint128(amount()))),
            abi.encodeCall(ISettlerActions.TRANSFER_OUT, (address(toToken()), BURN_ADDRESS, 1_000)),
            abi.encodeCall(ISettlerActions.TRANSFER_OUT, (address(toToken()), FROM, 10_000))
        );

        Settler _settler = settler;
        vm.startPrank(FROM);
        snapStartName("settler_otc_fee_full_custody");
        _settler.execute(actions);
        snapEnd();
    }

    /// @dev Performs a direct OTC trade between MAKER and FROM but with Settler receiving the buy token funds.
    /// Funds transfer
    ///   OTC
    ///     MAKER->Settler
    ///     TAKER->MAKER
    ///   TRANSFER_OUT
    ///     Settler->FEE_RECIPIENT
    ///     Settler->FROM
    function testSettler_otc_fee_single_custody() public {
        ISignatureTransfer.PermitTransferFrom memory takerPermit =
            defaultERC20PermitTransfer(address(fromToken()), uint160(amount()), PERMIT2_FROM_NONCE);
        bytes memory takerSig =
            getPermitTransferSignature(takerPermit, address(settler), FROM_PRIVATE_KEY, PERMIT2.DOMAIN_SEPARATOR());

        ISignatureTransfer.PermitTransferFrom memory makerPermit =
            defaultERC20PermitTransfer(address(toToken()), uint160(amount()), PERMIT2_MAKER_NONCE);

        OtcOrderSettlement.OtcOrder memory order = OtcOrderSettlement.OtcOrder({
            makerToken: address(toToken()),
            takerToken: address(fromToken()),
            makerAmount: uint128(amount()),
            takerAmount: uint128(amount()),
            maker: MAKER,
            taker: address(0),
            txOrigin: FROM
        });
        bytes32 witness = keccak256(abi.encode(order));
        bytes memory makerSig = getPermitWitnessTransferSignature(
            makerPermit,
            address(settler),
            MAKER_PRIVATE_KEY,
            OTC_PERMIT2_WITNESS_TYPEHASH,
            witness,
            PERMIT2.DOMAIN_SEPARATOR()
        );

        bytes[] memory actions = ActionDataBuilder.build(
            abi.encodeCall(
                ISettlerActions.SETTLER_OTC,
                (order, makerPermit, makerSig, takerPermit, takerSig, uint128(amount()), address(settler))
            ),
            abi.encodeCall(ISettlerActions.TRANSFER_OUT, (address(toToken()), BURN_ADDRESS, 1_000)),
            abi.encodeCall(ISettlerActions.TRANSFER_OUT, (address(toToken()), FROM, 10_000))
        );

        Settler _settler = settler;
        vm.startPrank(FROM, FROM);
        snapStartName("settler_otc_fee_single_custody");
        _settler.execute(actions);
        snapEnd();
    }

    function _getDefaultFromPermit2Action() private returns (bytes memory) {
        ISignatureTransfer.PermitTransferFrom memory permit =
            defaultERC20PermitTransfer(address(fromToken()), uint160(amount()), PERMIT2_FROM_NONCE);
        bytes memory sig =
            getPermitTransferSignature(permit, address(settler), FROM_PRIVATE_KEY, PERMIT2.DOMAIN_SEPARATOR());

        return abi.encodeCall(ISettlerActions.PERMIT2_TRANSFER_FROM, (permit, sig));
    }
}
