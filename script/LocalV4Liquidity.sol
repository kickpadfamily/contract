// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IPoolManager {
    struct PoolKey {
        address currency0;
        address currency1;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
    }

    struct ModifyLiquidityParams {
        int24 tickLower;
        int24 tickUpper;
        int256 liquidityDelta;
        bytes32 salt;
    }

    function initialize(PoolKey memory key, uint160 sqrtPriceX96) external returns (int24 tick);
    function unlock(bytes calldata data) external returns (bytes memory);
    function modifyLiquidity(PoolKey memory key, ModifyLiquidityParams memory params, bytes calldata hookData)
        external
        returns (int256 callerDelta, int256 feesAccrued);
    function sync(address currency) external;
    function settle() external payable returns (uint256);
}

/// @notice Localnet-only helper that initializes an ETH/quote Uniswap v4 pool and adds liquidity.
contract LocalV4Liquidity {
    using SafeERC20 for IERC20;

    IPoolManager public immutable poolManager;

    int24 internal constant MIN_TICK = -887272;
    int24 internal constant MAX_TICK = 887272;

    error OnlyPoolManager();

    constructor(address poolManager_) {
        poolManager = IPoolManager(poolManager_);
    }

    receive() external payable {}

    function seed(
        address quote,
        uint24 fee,
        int24 tickSpacing,
        uint160 sqrtPriceX96,
        int256 liquidityDelta,
        int24 tickHint
    ) external payable {
        IPoolManager.PoolKey memory key = IPoolManager.PoolKey({
            currency0: address(0),
            currency1: quote,
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: address(0)
        });
        int24 tick = tickHint;
        try poolManager.initialize(key, sqrtPriceX96) returns (int24 initialized) {
            tick = initialized;
        } catch {}
        poolManager.unlock(
            abi.encode(
                key,
                liquidityDelta,
                _usableTick(MIN_TICK, tickSpacing),
                _usableTick(MAX_TICK, tickSpacing)
            )
        );
        if (address(this).balance != 0) {
            (bool ok,) = msg.sender.call{value: address(this).balance}("");
            require(ok, "eth refund");
        }
        uint256 leftover = IERC20(quote).balanceOf(address(this));
        if (leftover != 0) IERC20(quote).safeTransfer(msg.sender, leftover);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        (IPoolManager.PoolKey memory key, int256 liquidityDelta, int24 tickLower, int24 tickUpper) =
            abi.decode(data, (IPoolManager.PoolKey, int256, int24, int24));

        (int256 callerDelta,) = poolManager.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: liquidityDelta,
                salt: bytes32(0)
            }),
            ""
        );

        (int128 amount0, int128 amount1) = _splitDelta(callerDelta);
        if (amount1 < 0) {
            uint256 owed = uint256(uint128(-amount1));
            poolManager.sync(key.currency1);
            IERC20(key.currency1).safeTransfer(address(poolManager), owed);
            poolManager.settle();
        }
        if (amount0 < 0) {
            poolManager.settle{value: uint256(uint128(-amount0))}();
        }
        return "";
    }

    function _splitDelta(int256 delta) private pure returns (int128 amount0, int128 amount1) {
        assembly ("memory-safe") {
            amount0 := sar(128, delta)
            amount1 := signextend(15, delta)
        }
    }

    function _usableTick(int24 tick, int24 spacing) private pure returns (int24) {
        int24 compressed = tick / spacing;
        if (tick < 0 && tick % spacing != 0) compressed--;
        int24 usable = compressed * spacing;
        if (usable < MIN_TICK) usable += spacing;
        if (usable > MAX_TICK) usable -= spacing;
        return usable;
    }
}
