// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

import {PoolId} from "v4-core/types/PoolId.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {PoolKey} from "v4-core/types/PoolKey.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";

import {Currency} from "v4-core/types/Currency.sol";

import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";

// uniswap-v4 test utils
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {GasPriceHook} from "src/GasPriceHook.sol";
import {console} from "forge-std/console.sol";

contract GasPriceHooktest is Test, Deployers {
    using StateLibrary for IPoolManager;
    using FixedPointMathLib for uint256;

    GasPriceHook hook;

    function setUp() public {
        // Deploy v4 core contracts
        deployFreshManagerAndRouters();

        // Deploy two test tokens

        deployMintAndApprove2Currencies();

        // deploy the hook
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG |
                Hooks.BEFORE_SWAP_FLAG |
                Hooks.AFTER_SWAP_FLAG
        );
        address hookAddress = address(flags);

        // set gas price = 10 gwei and then deploy
        vm.txGasPrice(10 gwei);

        deployCodeTo("GasPriceHook", abi.encode(manager, ""), hookAddress);

        // initialize hook
        hook = GasPriceHook(hookAddress);

        // initialize a pool
        (key, ) = initPool(
            currency0,
            currency1,
            hook,
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            SQRT_PRICE_1_1
        );

        // adding liquidity
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 100 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
    }

    function test_feeUpdatesWithGasPrice() public {
        // setup swap params
        PoolSwapTest.TestSettings memory testSetings = PoolSwapTest
            .TestSettings({takeClaims: false, settleUsingBurn: false});

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -0.00001 ether,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        // current gas price is 10 gwei
        // moving average will also be 10 gwei
        uint128 gasprice = uint128(tx.gasprice);
        uint128 movingAverageGasPrice = hook.movingAverageGasPrice();
        uint128 movingAverageGasPriceCount = hook.movingAverageGasPriceCount();
        assertEq(gasprice, 10 gwei);
        assertEq(movingAverageGasPrice, 10 gwei);
        assertEq(movingAverageGasPriceCount, 1);

        // 1. swap with gasprice = 10 gwei
        // This should just use the `BASE_FEE` since the gas price is same as current average
        uint256 balanceOfToken1Before = currency1.balanceOfSelf();
        swapRouter.swap(key, params, testSetings, ZERO_BYTES);
        uint256 balanceOfToken1After = currency1.balanceOfSelf();
        uint256 outpuFromBaseFeeSwap = balanceOfToken1After -
            balanceOfToken1Before;

        assertGt(balanceOfToken1After, balanceOfToken1Before);

        // moving average should not change, only moving average count will be incremented
        movingAverageGasPrice = hook.movingAverageGasPrice();
        movingAverageGasPriceCount = hook.movingAverageGasPriceCount();
        assertEq(movingAverageGasPrice, 10 gwei);
        assertEq(movingAverageGasPriceCount, 2);

        // swap at lower gas price
        // 2. swap with gas price = 4 gwei
        vm.txGasPrice(4 gwei);
        balanceOfToken1Before = currency1.balanceOfSelf();
        swapRouter.swap(key, params, testSetings, ZERO_BYTES);
        balanceOfToken1After = currency1.balanceOfSelf();
        uint256 outpuFromIncreasedBaseFeeSwap = balanceOfToken1After -
            balanceOfToken1Before;

        assertGt(balanceOfToken1After, balanceOfToken1Before);

        // moving average (10 + 10 + 4) / 3 = 8 gwei
        movingAverageGasPrice = hook.movingAverageGasPrice();
        movingAverageGasPriceCount = hook.movingAverageGasPriceCount();
        assertEq(movingAverageGasPrice, 8 gwei);
        assertEq(movingAverageGasPriceCount, 3);

        // gas price is higher comparatively
        // 3. swap with gas price = 12 gwei
        vm.txGasPrice(12 gwei);
        balanceOfToken1Before = currency1.balanceOfSelf();
        swapRouter.swap(key, params, testSetings, ZERO_BYTES);
        balanceOfToken1After = currency1.balanceOfSelf();
        uint256 outpuFromDecreasedBaseFeeSwap = balanceOfToken1After -
            balanceOfToken1Before;

        assertGt(balanceOfToken1After, balanceOfToken1Before);

        // moving average (10 + 10 + 4 + 12) / 4 = 9 gwei
        movingAverageGasPrice = hook.movingAverageGasPrice();
        movingAverageGasPriceCount = hook.movingAverageGasPriceCount();
        assertEq(movingAverageGasPrice, 9 gwei);
        assertEq(movingAverageGasPriceCount, 4);

        // 4. check all amounts
        console.log("Base Fee Output ", outpuFromBaseFeeSwap);
        console.log("Increased Fee Output ", outpuFromIncreasedBaseFeeSwap);
        console.log("Decreased Fee Output ", outpuFromDecreasedBaseFeeSwap);

        assertGt(outpuFromDecreasedBaseFeeSwap, outpuFromBaseFeeSwap);
        assertGt(outpuFromBaseFeeSwap, outpuFromIncreasedBaseFeeSwap);
    }
}
