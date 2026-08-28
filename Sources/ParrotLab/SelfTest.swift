import Foundation

enum ParrotLabSelfTest {
    static func run() -> Int32 {
        let parser = SC2TelemetryParser()
        var snapshot = TelemetrySnapshot()

        guard parser.consume(
            line: "I mpp (mppd): rssi_mpp:-42, rssi:-48, state:FLYING, altitude:21.5, latitude:38.1, longitude:21.7, roll:0.1, pitch:-0.2, yaw:1.5",
            into: &snapshot
        ), snapshot.sc2RSSI == -42,
           snapshot.reportedRSSI == -48,
           snapshot.flightState == "FLYING",
           snapshot.altitude == 21.5,
           snapshot.distanceFromHome == 0,
           snapshot.pitch == -0.2 else {
            fputs("Self-test failed: flight telemetry parser\n", stderr)
            return 1
        }

        _ = parser.consume(
            line: "I mpp (mppd): rssi_mpp:-42, rssi:-48, state:FLYING, altitude:22.0, latitude:38.101, longitude:21.7, roll:0.1, pitch:-0.2, yaw:1.5",
            into: &snapshot
        )
        _ = parser.consume(line: "__PARROTLAB_DRONE_BATTERY__=74", into: &snapshot)
        guard let distance = snapshot.distanceFromHome,
              (110...112).contains(distance),
              snapshot.droneBatteryPercent == 74 else {
            fputs("Self-test failed: drone distance/battery telemetry\n", stderr)
            return 1
        }

        _ = parser.consume(
            line: "I battery (dragon): Battery percentage : 63",
            into: &snapshot
        )
        guard snapshot.droneBatteryPercent == 63 else {
            fputs("Self-test failed: native drone battery telemetry\n", stderr)
            return 1
        }

        _ = parser.consume(
            line: "I bcmevtlog (wifid): extra_cnt: -37: -44: 0: 0: 1: 1: 1: 4: 1: 2: 0: -92: 22: 21: 4: 104: 0: 100: 0: 0",
            into: &snapshot
        )
        _ = parser.consume(
            line: "I proxy_drone (mppd): link_quality: tx_quality=-1%, rx_quality=99%, rx_useful=100%",
            into: &snapshot
        )
        guard snapshot.chain0RSSI == -37,
              snapshot.chain1RSSI == -44,
              snapshot.noise == -92,
              snapshot.rxQuality == 99,
              snapshot.rxUseful == 100,
              snapshot.txQuality == nil else {
            fputs("Self-test failed: RF telemetry parser\n", stderr)
            return 1
        }

        var sentinel = TelemetrySnapshot()
        _ = parser.consume(
            line: "rssi_mpp:-16, rssi:-20, state:LANDED, altitude:500.000000, latitude:500.000000, longitude:500.000000, roll:0.0, pitch:0.0, yaw:0.0",
            into: &sentinel
        )
        guard sentinel.altitude == nil, sentinel.latitude == nil, sentinel.longitude == nil else {
            fputs("Self-test failed: invalid-coordinate sentinel handling\n", stderr)
            return 1
        }

        let sdp = "HTTP/1.1 200 OK\r\n\r\nc=IN IP4 192.168.42.88\nm=video 55004 RTP/AVP 96\n"
        guard RestreamProbe.firstCapture(#"m=video\s+(\d+)"#, in: sdp) == "55004" else {
            fputs("Self-test failed: restream SDP parser\n", stderr)
            return 1
        }

        guard RTPH264Receiver.assemblySelfTest() else {
            fputs("Self-test failed: RTP/H.264 assembler\n", stderr)
            return 1
        }

        guard VideoReceiveMode.selfTest() else {
            fputs("Self-test failed: video receive mode\n", stderr)
            return 1
        }
        guard DragonVideoProfile.selfTest() else {
            fputs("Self-test failed: Dragon profile/custom launch\n", stderr)
            return 1
        }
        guard BebopToolInstaller.selfTest() else {
            fputs("Self-test failed: bundled device tools\n", stderr)
            return 1
        }
        guard H264VideoView.metadataSelfTest() else {
            fputs("Self-test failed: FrameInfo metadata\n", stderr)
            return 1
        }
        guard VideoMetadataV2.selfTest(), RTPVideoTimestampMapper.selfTest() else {
            fputs("Self-test failed: synchronized video metadata/timing\n", stderr)
            return 1
        }
        guard Bebop900pCameraCalibration.selfTest(),
              Bebop900pCalibrationTextureSet.selfTest(),
              RollingShutterMetalRenderer.selfTest() else {
            fputs("Self-test failed: calibrated 900p camera/readout mapping\n", stderr)
            return 1
        }
        guard TemporalReconstructionRenderer.selfTest() else {
            fputs("Self-test failed: temporal reconstruction renderer\n", stderr)
            return 1
        }
        guard H264ArtifactRepairRenderer.selfTest() else {
            fputs("Self-test failed: H.264 artifact repair renderer\n", stderr)
            return 1
        }

        guard FFmpegVideoDecoder.bufferingSelfTest() else {
            fputs("Self-test failed: bounded video buffering\n", stderr)
            return 1
        }

        let telnetMarker = "__PARROTLAB_TELNET__="
        guard SC2TelemetryParser.deviceMarkerPayload(
            telnetMarker,
            in: "__PARROTLAB_TELNET__=INSTALLED"
        ) == "INSTALLED",
        SC2TelemetryParser.deviceMarkerPayload(
            telnetMarker,
            in: "if bad; then echo __PARROTLAB_TELNET__=ERROR_DIGEST; elif good"
        ) == nil else {
            fputs("Self-test failed: echoed device-result marker rejection\n", stderr)
            return 1
        }

        guard MediaFileNamer.selfTest(), StillImageWriter.selfTest(),
              H264StreamRecorder.selfTest(), ProcessedH264Recorder.selfTest(),
              H264MP4Converter.selfTest(),
              ARSDKPhotoCaptureSelfTest.run(),
              ARSDKTelemetryReducer.selfTest(),
              DroneMediaFTP.selfTest() else {
            fputs("Self-test failed: local media capture\n", stderr)
            return 1
        }

        print("Parrot Lab self-test passed")
        return 0
    }
}
