// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Valid UTF-8 that can be inserted inside a JSON string without escaping.
library JsonText {
    error InvalidText();

    function check(bytes memory text, uint256 maximum, bool allowEmpty) internal pure {
        if ((!allowEmpty && text.length == 0) || text.length > maximum) revert InvalidText();
        uint256 i;
        while (i < text.length) {
            uint8 c = uint8(text[i]);
            if (c < 0x80) {
                if (c < 0x20 || c == 0x22 || c == 0x5c) revert InvalidText();
                ++i;
                continue;
            }
            uint256 n;
            if (c >= 0xc2 && c <= 0xdf) n = 2;
            else if (c >= 0xe0 && c <= 0xef) n = 3;
            else if (c >= 0xf0 && c <= 0xf4) n = 4;
            else revert InvalidText();
            if (i + n > text.length) revert InvalidText();
            uint8 second = uint8(text[i + 1]);
            // Reject overlong encodings, UTF-16 surrogates and code points above U+10FFFF.
            if (
                (c == 0xe0 && second < 0xa0) || (c == 0xed && second >= 0xa0) || (c == 0xf0 && second < 0x90)
                    || (c == 0xf4 && second >= 0x90)
            ) revert InvalidText();
            for (uint256 j = 1; j < n; ++j) {
                uint8 continuation = uint8(text[i + j]);
                if (continuation < 0x80 || continuation > 0xbf) revert InvalidText();
            }
            i += n;
        }
    }
}
