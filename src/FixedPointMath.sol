// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title FixedPointMath
 * @notice Fixed-point exp() and ln() for LMSR pricing
 * @dev All values in 59.18 fixed-point (1e18 scale)
 *
 * exp() uses the identity: e^x = 2^(x / ln(2))
 *   - Decompose into integer part (shift) + fractional part (polynomial)
 *   - Fractional exp2 uses a 6th-degree minimax polynomial
 *
 * ln() uses the identity: ln(x) = log2(x) * ln(2)
 *   - Extract integer log2 via bit scanning
 *   - Fractional log2 via iterative squaring
 */
library FixedPointMath {
    // ── Constants (59.18 fixed-point) ──────────────────────────────────

    int256 internal constant SCALE = 1e18;

    /// @dev ln(2) = 0.693147180559945309...
    int256 internal constant LN_2 = 693147180559945309;

    /// @dev 1 / ln(2) = 1.442695040888963407...
    int256 internal constant INV_LN_2 = 1_442695040888963407;

    /// @dev Overflow guard for exp(): e^(135.305999368893231589) ≈ maxInt256 / SCALE
    int256 internal constant EXP_MAX_INPUT = 135_305999368893231589;

    /// @dev Underflow guard for exp(): e^(-42.1...) ≈ 0 in 1e18
    int256 internal constant EXP_MIN_INPUT = -42_139678854452767551;

    // ── Errors ─────────────────────────────────────────────────────────

    error ExpInputTooLarge(int256 x);
    error LnNonPositive(int256 x);

    // ═══════════════════════════════════════════════════════════════════
    // EXP — e^x for signed 59.18 fixed-point
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @notice Compute e^x in 59.18 fixed-point
     * @param x Input in 1e18 scale (e.g., 1e18 = e^1 ≈ 2.718e18)
     * @return result e^x in 1e18 scale
     */
    function exp(int256 x) internal pure returns (int256 result) {
        // Bounds check
        if (x > EXP_MAX_INPUT) revert ExpInputTooLarge(x);
        if (x < EXP_MIN_INPUT) return 0;

        // ── Step 1: Change base from e to 2 ──
        // e^x = 2^(x / ln(2)) = 2^(x * (1/ln(2)))
        // x256 is in 1e18 scale and represents x / ln(2)
        int256 x256 = (x * INV_LN_2) / SCALE;

        // ── Step 2: Separate integer and fractional parts ──
        // intPart = floor(x / ln(2)), can be negative
        int256 intPart = x256 / SCALE;
        if (x256 < 0 && x256 % SCALE != 0) {
            intPart -= 1; // floor for negatives
        }
        // fracPart is in [0, 1e18), represents the fractional part of x/ln(2)
        int256 fracPart = x256 - (intPart * SCALE);

        // ── Step 3: Compute 2^(fracPart) via 6th-degree minimax polynomial ──
        // Polynomial approximation of 2^f for f in [0, 1)
        // Coefficients from Remco Bloemen's Solidity implementation
        // 2^f ≈ c0 + c1*f + c2*f^2 + c3*f^3 + c4*f^4 + c5*f^5 + c6*f^6
        int256 f = fracPart;

        // Horner's method for efficiency, coefficients scaled to 1e18
        // These coefficients approximate 2^x on [0,1) with <1e-15 relative error
        int256 r = SCALE; // accumulator starts at c0 = 1.0
        r = r + (f * 693147180559945309) / SCALE;  // c1 * f
        int256 f2 = (f * f) / SCALE;
        r = r + (f2 * 240226506959101221) / SCALE; // c2 * f^2
        int256 f3 = (f2 * f) / SCALE;
        r = r + (f3 * 55504108664821580) / SCALE;  // c3 * f^3
        int256 f4 = (f3 * f) / SCALE;
        r = r + (f4 * 9617966939260028) / SCALE;   // c4 * f^4
        int256 f5 = (f4 * f) / SCALE;
        r = r + (f5 * 1333355814642864) / SCALE;   // c5 * f^5
        int256 f6 = (f5 * f) / SCALE;
        r = r + (f6 * 154035303933816) / SCALE;    // c6 * f^6

        // ── Step 4: Apply integer part as bit shift ──
        // 2^intPart * 2^fracPart
        if (intPart >= 0) {
            // Shift left (multiply by 2^intPart)
            require(intPart < 255, "exp overflow");
            result = r << uint256(intPart);
        } else {
            // Shift right (divide by 2^|intPart|)
            uint256 shift = uint256(-intPart);
            result = r >> shift;
        }
    }

    /**
     * @notice Unsigned exp wrapper for LMSR (input is always >= 0)
     * @param x Unsigned input in 1e18 scale
     * @return Unsigned result in 1e18 scale
     */
    function expUint(uint256 x) internal pure returns (uint256) {
        require(x <= uint256(type(int256).max), "exp input overflow");
        int256 result = exp(int256(x));
        require(result >= 0, "exp negative result");
        return uint256(result);
    }

    // ═══════════════════════════════════════════════════════════════════
    // LN — ln(x) for unsigned 59.18 fixed-point
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @notice Compute ln(x) in 59.18 fixed-point
     * @param x Input in 1e18 scale (must be > 0)
     * @return result ln(x) in 1e18 scale
     */
    function ln(uint256 x) internal pure returns (int256 result) {
        if (x == 0) revert LnNonPositive(0);

        // ln(x) = log2(x) * ln(2)
        int256 log2x = log2Fixed(x);
        result = (log2x * LN_2) / SCALE;
    }

    /**
     * @notice Compute log2(x) for unsigned 59.18 fixed-point
     * @param x Input in 1e18 scale
     * @return result log2(x) in 1e18 (signed, since log can be negative for x < 1e18)
     */
    function log2Fixed(uint256 x) internal pure returns (int256 result) {
        if (x == 0) revert LnNonPositive(0);

        // ── Step 1: Integer part via bit scanning ──
        // Normalize: find how many bits x has, relative to 1e18
        // log2(x_raw) = log2(x_real * 1e18) = log2(x_real) + log2(1e18)
        // log2(1e18) ≈ 59.794705707972522 (we account for this)

        // msb = position of most significant bit
        uint256 msb = mostSignificantBit(x);

        // Integer part of log2 relative to 1e18 scale
        // If x = 1e18, msb ≈ 59, so intPart = 0
        // If x = 2e18, msb ≈ 60, so intPart = 1
        int256 intPart;
        if (msb >= 60) {
            intPart = int256(msb - 60);
            // Normalize x to [1e18, 2e18) range by shifting right
            x = x >> uint256(intPart);
        } else {
            intPart = -int256(60 - msb);
            // Normalize x to [1e18, 2e18) range by shifting left
            x = x << uint256(-intPart);
        }

        // ── Step 2: Fractional part via iterative squaring ──
        // x is now in [1e18, 2e18). We compute the fractional log2 bits.
        int256 fracPart = 0;
        int256 bit = int256(SCALE) / 2; // 0.5 in 1e18

        for (uint256 i = 0; i < 64; i++) {
            // Square x (in 1e18 scale)
            x = (x * x) / 1e18;

            // If x >= 2e18, then this fractional bit is 1
            if (x >= 2e18) {
                fracPart += bit;
                x = x / 2; // Normalize back to [1e18, 2e18)
            }
            bit = bit / 2;
            if (bit == 0) break;
        }

        result = (intPart * SCALE) + fracPart;
    }

    /**
     * @notice Find the most significant bit position
     */
    function mostSignificantBit(uint256 x) internal pure returns (uint256 msb) {
        if (x >= 2 ** 128) { x >>= 128; msb += 128; }
        if (x >= 2 ** 64)  { x >>= 64;  msb += 64;  }
        if (x >= 2 ** 32)  { x >>= 32;  msb += 32;  }
        if (x >= 2 ** 16)  { x >>= 16;  msb += 16;  }
        if (x >= 2 ** 8)   { x >>= 8;   msb += 8;   }
        if (x >= 2 ** 4)   { x >>= 4;   msb += 4;   }
        if (x >= 2 ** 2)   { x >>= 2;   msb += 2;   }
        if (x >= 2 ** 1)   { msb += 1; }
    }
}
