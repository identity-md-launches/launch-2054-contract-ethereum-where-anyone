// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {JsonText} from "src/libraries/JsonText.sol";
import {BuyerTestBase} from "./helpers/BuyerTestBase.sol";

contract JsonTextProbe {
    function check(bytes calldata value, uint256 maximum, bool allowEmpty) external pure {
        JsonText.check(value, maximum, allowEmpty);
    }
}

/// forge-config: default.fuzz.runs = 1000
contract JsonTextPropertiesTest is BuyerTestBase {
    JsonTextProbe internal probe;

    function setUp() public override {
        super.setUp();
        probe = new JsonTextProbe();
    }

    function testAllASCIIBytesHaveTheExpectedJSONSafety() public {
        for (uint256 c; c < 128; ++c) {
            bytes memory input = abi.encodePacked(bytes1(uint8(c)));
            if (c < 32 || c == 34 || c == 92) {
                vm.expectRevert(JsonText.InvalidText.selector);
                probe.check(input, 1, false);
            } else {
                probe.check(input, 1, false);
                _assertRoundTrip(string(input));
            }
        }
    }

    function testUTF8BoundaryCodePointsRoundTripWithoutChangingWords() public view {
        // First and last scalar in each encoding range, either side of surrogates,
        // and the highest legal scalar. These are generated independently of JsonText.
        uint256[12] memory points =
            [uint256(0x20), 0x7f, 0x80, 0x7ff, 0x800, 0xd7ff, 0xe000, 0xffff, 0x10000, 0x3ffff, 0x100000, 0x10ffff];
        for (uint256 i; i < points.length; ++i) {
            _assertRoundTrip(string(_encodeScalar(points[i])));
        }
    }

    function testFuzzUnicodeScalarsRoundTripThroughIndependentJSONParser(uint32 seed, uint8 repetitions) public view {
        uint256 point = bound(seed, 0x20, 0x10ffff - 0x800);
        if (point >= 0xd800) point += 0x800; // Exclude the surrogate gap by construction.
        if (point == 0x22 || point == 0x5c) ++point;
        bytes memory scalar = _encodeScalar(point);
        uint256 count = bound(repetitions, 1, 32);
        bytes memory words = new bytes(scalar.length * count);
        for (uint256 i; i < words.length; ++i) {
            words[i] = scalar[i % scalar.length];
        }
        _assertRoundTrip(string(words));
    }

    function testOverlongSurrogateOutOfRangeTruncatedAndStraySequencesRevert() public {
        bytes[16] memory invalid = [
            bytes(hex"c0af"),
            hex"c1bf",
            hex"e080af",
            hex"f08080af",
            hex"eda080",
            hex"edbfbf",
            hex"f4908080",
            hex"f5808080",
            hex"ff",
            hex"80",
            hex"c2",
            hex"e0a0",
            hex"f09080",
            hex"e24180",
            hex"f0907f80",
            hex"f09080c0"
        ];
        for (uint256 i; i < invalid.length; ++i) {
            vm.expectRevert(JsonText.InvalidText.selector);
            probe.check(invalid[i], 2000, false);
            vm.expectRevert(JsonText.InvalidText.selector);
            buyer.bodyOf(0, alice, string(invalid[i]));
        }
    }

    function testFuzzBreakingAnyContinuationByteIsRejected(uint32 seed, uint8 position, uint8 ascii) public {
        uint256 point = bound(seed, 0x80, 0x10ffff - 0x800);
        if (point >= 0xd800) point += 0x800;
        bytes memory encoded = _encodeScalar(point);
        uint256 at = bound(position, 1, encoded.length - 1);
        encoded[at] = bytes1(uint8(bound(ascii, 0x20, 0x7f)));
        vm.expectRevert(JsonText.InvalidText.selector);
        probe.check(encoded, 2000, false);
    }

    function testMaximumIsAByteLimitAndDoesNotPermitTruncatedScalars() public {
        string memory allowed = string.concat(_repeat("a", 1998), unicode"é");
        assertEq(bytes(allowed).length, 2000);
        _assertRoundTrip(allowed);
        vm.expectRevert(JsonText.InvalidText.selector);
        buyer.bodyOf(0, alice, string.concat(_repeat("a", 1999), unicode"é"));
        bytes memory truncated = bytes.concat(bytes(_repeat("a", 1999)), hex"c3");
        vm.expectRevert(JsonText.InvalidText.selector);
        buyer.bodyOf(0, alice, string(truncated));
        probe.check("", 0, true);
        vm.expectRevert(JsonText.InvalidText.selector);
        probe.check("", 0, false);
        vm.expectRevert(JsonText.InvalidText.selector);
        probe.check("a", 0, true);
    }

    function _assertRoundTrip(string memory words) internal view {
        string memory body = string(buyer.bodyOf(0, alice, words));
        assertEq(vm.parseJsonString(body, ".objective"), string.concat("Build a one-page website: ", words));
        assertEq(vm.parseJsonString(body, ".skill"), "build-website");
        assertTrue(vm.parseJsonBool(body, ".host"));
        assertEq(vm.parseJsonAddress(body, ".owner"), alice);
    }

    /// @dev Encode a Unicode scalar using bit arithmetic, as an independent input generator.
    function _encodeScalar(uint256 point) internal pure returns (bytes memory) {
        if (point < 0x80) return abi.encodePacked(bytes1(uint8(point)));
        if (point < 0x800) {
            return abi.encodePacked(bytes1(uint8(0xc0 | (point >> 6))), bytes1(uint8(0x80 | (point & 0x3f))));
        }
        if (point < 0x10000) {
            return abi.encodePacked(
                bytes1(uint8(0xe0 | (point >> 12))),
                bytes1(uint8(0x80 | ((point >> 6) & 0x3f))),
                bytes1(uint8(0x80 | (point & 0x3f)))
            );
        }
        return abi.encodePacked(
            bytes1(uint8(0xf0 | (point >> 18))),
            bytes1(uint8(0x80 | ((point >> 12) & 0x3f))),
            bytes1(uint8(0x80 | ((point >> 6) & 0x3f))),
            bytes1(uint8(0x80 | (point & 0x3f)))
        );
    }
}
