import SwiftUI
import AppKit

struct WebUISettingsPanel: View {
    @EnvironmentObject var webRTCManager: WebRTCManager
    @EnvironmentObject var inputManager: InputManager
    @EnvironmentObject var kvmDeviceManager: KVMDeviceManager

    @Binding var isPresented: Bool

    @AppStorage("overlook.appAppearance") private var appAppearance: String = "system"

    @AppStorage("overlook.audio.inputDeviceUID") private var audioInputDeviceUID: String = ""
    @AppStorage("overlook.audio.outputDeviceUID") private var audioOutputDeviceUID: String = ""

    @State private var config: GLKVMSystemConfig?
    @State private var keymaps: GLKVMHidKeymapsState?
    @State private var streamerState: GLKVMStreamerState?
    @State private var isLoading = false
    @State private var isApplying = false
    @State private var isApplyingStreamer = false
    @State private var isApplyingEdid = false
    @State private var errorMessage: String?

    private struct ErrorEntry: Identifiable, Hashable {
        let id = UUID()
        let date: Date
        let message: String
    }

    @State private var errorHistory: [ErrorEntry] = []
    @State private var showingErrorHistory: Bool = false

    @State private var isVideoExpanded = true
    @State private var isRemoteExpanded = true
    @State private var isKeyboardExpanded = true
    @State private var isAudioExpanded = false
    @State private var isSystemExpanded = false
    @State private var isNetworkExpanded = false
    @State private var isAdvancedExpanded = false

    @State private var currentEdid: String = ""
    @State private var selectedEdidOption: String = "CUSTOMIZE"
    @State private var customEdidDraft: String = ""
    @State private var isProgrammaticEdidSelectionUpdate: Bool = false

    @State private var selectedVideoQualityPreset: Int = 1

    @State private var applyTask: Task<Void, Never>?
    @State private var applyStreamerTask: Task<Void, Never>?

    @State private var isProgrammaticStreamerDraftUpdate: Bool = false

    @State private var streamerDesiredFps: Int = 30
    @State private var streamerQuality: Int = 80
    @State private var streamerH264Bitrate: Int = 2000
    @State private var streamerH264Gop: Int = 30
    @State private var streamerZeroDelay: Bool = false
    @State private var streamerResolution: String = ""

    @State private var audioInputDevices: [CoreAudioDeviceInfo] = []
    @State private var audioOutputDevices: [CoreAudioDeviceInfo] = []

    @State private var streamerDesiredFpsText: String = ""
    @State private var streamerQualityText: String = ""
    @State private var streamerH264BitrateText: String = ""
    @State private var streamerH264GopText: String = ""

    private var streamerFeatures: GLKVMStreamerState.Features? { streamerState?.features }
    private var streamerLimits: GLKVMStreamerState.Limits? { streamerState?.limits }

    private enum StreamerField: Hashable {
        case fps
        case quality
        case bitrate
        case gop
        case resolution
    }

    @FocusState private var focusedStreamerField: StreamerField?

    private let panelBackground = Color(NSColor.windowBackgroundColor)
    private let processingOptions: [(String, String)] = [
        ("low_latency_first", "Low latency"),
        ("quality_first", "Smart"),
    ]

    private let videoQualityCustomTag: Int = -1
    private let videoQualityInsaneTag: Int = 4

    private let appAppearanceOptions: [(String, String)] = [
        ("system", "System"),
        ("light", "Light"),
        ("dark", "Dark"),
    ]

    private let integerFormatter: NumberFormatter = {
        let nf = NumberFormatter()
        nf.numberStyle = .none
        nf.generatesDecimalNumbers = false
        return nf
    }()

    private let reverseScrollingOptions: [(String, String)] = [
        ("STANDARD", "Standard"),
        ("VERTICAL", "Vertical"),
        ("HORIZONTAL", "Horizontal"),
        ("BOTH", "Both"),
    ]

    private let themeOptions: [(String, String)] = [
        ("0", "Light"),
        ("1", "Dark"),
    ]

    private struct EDIDOption: Hashable {
        let id: String
        let label: String
        let edid: String?
    }

    private let edidOptions: [EDIDOption] = [
        EDIDOption(
            id: "E2560x1440",
            label: "2560x1440/GLKVM/60Hz",
            edid: "00 ff ff ff ff ff ff 00 1d 89 1c c2 8a 0e 00 00\n        08 1f 01 03 80 3c 22 78 2a 2d 71 af 4f 44 a9 27\n        0d 50 54 21 08 00 d1 c0 95 c0 95 00 81 80 81 40\n        81 c0 01 01 01 01 56 5e 00 a0 a0 a0 29 50 30 20\n        35 00 55 50 21 00 00 1e 00 00 00 ff 00 38 39 31\n        32 34 37 0a 20 20 20 20 20 20 00 00 00 fc 00 47\n        4c 4b 56 4d 0a 20 20 20 20 20 20 20 00 00 00 fd\n        00 30 4b 1e 72 1e 00 0a 20 20 20 20 20 20 01 5d\n\n        02 03 27 f0 4b 10 1f 05 14 04 13 03 12 02 11 01\n        23 09 07 07 83 01 00 00 65 03 0c 00 10 00 68 1a\n        00 00 01 01 30 4b 00 02 3a 80 18 71 38 2d 40 58\n        2c 45 00 55 50 21 00 00 1e 8c 0a d0 8a 20 e0 2d\n        10 10 3e 96 00 55 50 21 00 00 18 8c 0a d0 90 20\n        40 31 20 0c 40 55 00 55 50 21 00 00 18 f0 3c 00\n        d0 51 a0 35 50 60 88 3a 00 55 50 21 00 00 1c 00\n        00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 ae"
        ),
        EDIDOption(
            id: "E3840x2160",
            label: "3840x2160/GLKVM/30Hz",
            edid: "00 ff ff ff ff ff ff 00 32 8d 32 31 00 88 88 88\n        20 1e 01 03 80 0c 07 78 0a 0d c9 a0 57 47 98 27\n        12 48 4c 00 00 00 01 01 01 01 01 01 01 01 01 01\n        01 01 01 01 01 01 02 3a 80 18 71 38 2d 40 58 2c\n        45 00 13 2b 21 00 00 1e 00 00 00 ff 00 30 30 30\n        30 30 30 30 30 30 30 30 30 30 30 30 0a 00 00 00\n        fd 00 18 3c 1e 53 11 00 0a 20 20 20 20 20 20 00\n        00 00 fc 00 47 4c 4b 56 4d 0a 20 20 20 20 20 20\n        20 01 10\n\n        02 03 18 c1 48 90 1f 04 13 03 12 01 23 09 07 01\n        83 01 00 00 65 03 0c 00 10 00 8c 0a d0 8a 20 e0\n        2d 10 10 3e 96 00 13 2b 21 00 00 18 00 00 00 00\n        00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00\n        00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 62"
        ),
        EDIDOption(
            id: "E1920x1080",
            label: "1920x1080/ASUS/60Hz",
            edid: "00 ff ff ff ff ff ff 00 06 b3 b2 24 01 01 01 01\n        21 1e 01 03 80 35 1e 78 0e ee 91 a3 54 4c 99 26\n        0f 50 54 21 08 00 01 01 01 01 01 01 01 01 01 01\n        01 01 01 01 01 01 02 3a 80 18 71 38 2d 40 58 2c\n        45 00 13 2b 21 00 00 1e 00 00 00 ff 00 4c 38 4c\n        4d 51 53 30 37 35 33 39 32 20 00 00 00 fd 00 18\n        3c 1e 5a 1e 01 0a 20 20 20 20 20 20 00 00 00 fc\n        00 52 4f 47 20 50 47 32 34 38 51 0a 20 20 01 99\n\n        02 03 1a c1 47 90 1f 04 13 03 12 01 23 09 07 01\n        83 01 00 00 65 03 0c 00 10 00 00 00 00 00 00 00\n        00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00\n        00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00\n        00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00\n        00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00\n        00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00\n        00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 c1"
        ),
        EDIDOption(
            id: "E1920x1200",
            label: "1920x1200/Samsung/60Hz",
            edid: "00 ff ff ff ff ff ff 00 4c a3 0b a7 01 01 01 01\n        08 1a 01 03 80 00 00 78 0a de 50 a3 54 4c 99 26\n        0f 50 54 a1 08 00 81 40 81 c0 95 00 81 80 90 40\n        b3 00 a9 40 01 01 28 3c 80 a0 70 b0 23 40 30 20\n        36 00 40 84 63 00 00 1a 9e 20 00 90 51 20 1f 30\n        48 80 36 00 40 84 63 00 00 1c 00 00 00 fd 00 17\n        55 0f 5c 11 00 0a 20 20 20 20 20 20 00 00 00 fc\n        00 45 50 53 4f 4e 20 50 4a 0a 20 20 20 20 01 15\n\n        02 03 28 f1 51 90 1f 20 22 05 14 04 13 03 02 12\n        11 07 06 16 15 01 23 09 07 07 83 01 00 00 66 03\n        0c 00 20 00 80 e2 00 fb 02 3a 80 18 71 38 2d 40\n        58 2c 45 00 40 84 63 00 00 1e 01 1d 80 18 71 38\n        2d 40 58 2c 45 00 40 84 63 00 00 1e 66 21 56 aa\n        51 00 1e 30 46 8f 33 00 40 84 63 00 00 1e 30 2a\n        40 c8 60 84 64 30 18 50 13 00 40 84 63 00 00 1e\n        00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 80"
        ),
        EDIDOption(
            id: "E1920x1280",
            label: "1920x1280/AUO/60Hz",
            edid: "00 ff ff ff ff ff ff 00 06 af 8d 93 00 00 00 00\n        0f 20 01 04 a5 1a 11 78 03 24 45 9b 53 4c 8e 27\n        16 50 54 00 00 00 01 01 01 01 01 01 01 01 01 01\n        01 01 01 01 01 01 62 3e 80 64 70 00 26 50 28 10\n        66 00 05 ae 10 00 00 18 00 00 00 fd 00 30 3c 50\n        50 10 00 00 00 00 00 00 00 20 00 00 00 fe 00 47\n        31 32 34 55 41 4e 30 31 2e 30 00 00 00 00 00 fe\n        00 52 51 39 33 48 32 46 57 37 44 33 34 00 00 ef"
        ),
        EDIDOption(
            id: "E2560x1440VS",
            label: "2560x1440/ViewSonic/60Hz",
            edid: "00 ff ff ff ff ff ff 00 5a 63 34 2f ea 50 00 00\n        24 1e 01 03 80 35 1e 78 2e ff d5 a9 53 45 a0 25\n        0d 50 54 bf ef 80 d1 c0 b3 00 a9 40 a9 c0 95 00\n        90 40 81 80 81 c0 56 5e 00 a0 a0 a0 29 50 30 20\n        35 00 0f 28 21 00 00 1a 00 00 00 fd 00 32 4c 1e\n        53 1e 00 0a 20 20 20 20 20 20 00 00 00 fc 00 56\n        58 32 34 37 38 2d 32 0a 20 20 20 20 00 00 00 ff\n        00 55 59 4c 32 30 33 36 32 30 37 31 34 0a 01 ea\n\n        02 03 24 f1 4f 90 05 04 03 02 07 12 13 14 16 1f\n        20 21 22 01 23 09 7f 07 83 01 00 00 67 03 0c 00\n        10 00 20 40 02 3a 80 18 71 38 2d 40 58 2c 45 00\n        0f 28 21 00 00 1e 01 1d 80 18 71 1c 16 20 58 2c\n        25 00 0f 28 21 00 00 9e 01 1d 00 72 51 d0 1e 20\n        6e 28 55 00 0f 28 21 00 00 1e 02 3a 80 d0 72 38\n        2d 40 10 2c 45 80 0f 28 21 00 00 1e 01 1d 80 d0\n        72 1c 16 20 10 2c 25 80 0f 28 21 00 00 9e 00 50"
        ),
        EDIDOption(
            id: "E1600x1200",
            label: "1600x1200/Wacom/60Hz",
            edid: "00 ff ff ff ff ff ff 00 5c 23 14 10 76 01 00 00\n        21 12 01 03 81 2c 21 78 aa a5 d5 a6 54 4a 9c 23\n        14 50 54 bf ef 00 31 59 45 59 61 59 81 80 81 99\n        a9 40 01 01 01 01 48 3f 40 30 62 b0 32 40 40 c0\n        13 00 b0 44 11 00 00 1e 00 00 00 fd 00 38 55 1f\n        5c 11 00 0a 20 20 20 20 20 20 00 00 00 ff 00 38\n        48 43 30 30 30 33 37 34 20 20 20 20 00 00 00 fc\n        00 43 69 6e 74 69 71 32 31 55 58 0a 20 20 00 39"
        ),
        EDIDOption(
            id: "E2560x1664AOC",
            label: "2560x1664/AOC/50Hz",
            edid: "00 ff ff ff ff ff ff 00 05 e3 77 25 24 00 00 00\n        01 1e 01 04 a5 37 1f 78 3a 44 55 a9 55 4d 9d 26\n        0f 50 54 21 08 00 d1 c0 b3 00 95 00 81 80 81 40\n        81 c0 01 01 01 01 6e 5a 00 a0 a0 80 28 60 30 20\n        3a 00 29 37 21 00 00 1e 00 00 00 fd 00 1e 3c 1e\n        63 1e 00 0a 20 20 20 20 20 20 00 00 00 fc 00 47\n        4c 4b 56 4d 0a 20 20 20 20 20 20 20 00 00 00 ff\n        00 41 48 4c 4c 31 39 41 30 30 30 33 36 01 d5\n        02 03 1e f1 4b 01 03 05 14 04 13 1f 12 02 11 90\n        23 09 07 07 83 01 00 00 65 03 0c 00 10 00 02 3a\n        80 18 71 38 2d 40 58 2c 45 00 29 37 21 00 00 1e\n        01 1d 00 72 51 d0 1e 20 6e 28 55 00 29 37 21 00\n        00 1e 8c 0a d0 8a 20 e0 2d 10 10 3e 96 00 29 37\n        21 00 00 18 8c 0a d0 90 20 40 31 20 0c 40 55 00\n        29 37 21 00 00 18 f0 3c 00 d0 51 a0 35 50 60 88\n        3a 00 29 37 21 00 00 1c 00 00 00 00 00 00 00 d0\n        "
        ),
        EDIDOption(
            id: "E2560x1600LTM",
            label: "2560x1600/LTM/50Hz",
            edid: "00 ff ff ff ff ff ff 00 32 8d 32 31 00 88 88 88\n        20 1e 01 03 80 0c 07 78 0a 0d c9 a0 57 47 98 27\n        12 48 4c 00 00 00 01 01 01 01 01 01 01 01 01 01\n        01 01 01 01 01 01 03 57 00 a0 a0 40 26 60 30 20\n        36 00 00 40 a6 00 00 1e 02 3a 80 18 71 38 2d 40\n        58 2c 45 00 c4 8e 21 00 00 1e 00 00 00 fd 00 18\n        64 14 96 1e 00 0a 20 20 20 20 20 20 00 00 00 fc\n        00 41 53 55 53 0a 20 20 20 20 20 20 20 20 01 f0\n        02 03 1d f0 4a 01 04 10 1f 20 21 22 5d 5e 5f 23\n        09 04 01 83 01 00 00 65 03 0c 00 10 00 00 00 00\n        00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00\n        00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00\n        00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00\n        00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00\n        00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00\n        00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 ba\n        "
        ),
        EDIDOption(
            id: "E3440x1440AOC",
            label: "3440x1440/AOC/50Hz",
            edid: "00 ff ff ff ff ff ff 00 05 e3 25 35 01 01 01 01\n        00 1a 01 03 80 52 23 78 0e ee 91 a3 54 4c 99 26\n        0f 50 54 21 08 00 01 01 01 01 01 01 01 01 01 01\n        01 01 01 01 01 01 9d 67 70 a0 d0 a0 22 50 30 20\n        3a 00 33 5a 31 00 00 1a 00 00 00 ff 00 0a 20 20\n        20 20 20 20 20 20 20 20 20 20 00 00 00 fd 00 18\n        3c 1e 8c 1e 01 0a 20 20 20 20 20 20 00 00 00 fc\n        00 41 47 33 35 32 55 43 47 0a 20 20 20 20 01 6d\n\n        02 03 1a c1 47 90 1f 04 13 03 12 01 23 09 07 01\n        83 01 00 00 65 03 0c 00 10 00 00 00 00 00 00 00\n        00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00\n        00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00\n        00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00\n        00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00\n        00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00\n        00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 c1\n        "
        ),
        EDIDOption(
            id: "E2560x1080AOC",
            label: "2560x1080/AOC/60Hz",
            edid: "00 ff ff ff ff ff ff 00 05 e3 63 29 4b 01 00 00\n        0a 17 01 03 80 43 1c 78 2a ca 95 a6 55 4e a1 26\n        0f 50 54 bf ef 00 d1 c0 b3 00 95 00 81 80 81 40\n        81 c0 01 01 01 01 cd 46 00 a0 a0 38 1f 40 30 20\n        3a 00 a1 1c 21 00 00 1a 02 3a 80 18 71 38 2d 40\n        58 2c 45 00 a1 1c 21 00 00 1e 00 00 00 fd 00 32\n        4c 1e 63 1e 00 0a 20 20 20 20 20 20 00 00 00 fc\n        00 32 39 36 33 0a 20 20 20 20 20 20 20 20 01 16\n\n        02 03 1f f1 4c 05 14 10 1f 04 13 03 12 02 11 01\n        22 23 09 07 01 83 01 00 00 65 03 0c 00 10 00 02\n        3a 80 18 71 38 2d 40 58 2c 45 00 a1 1c 21 00 00\n        1e 01 1d 00 72 51 d0 1e 20 6e 28 55 00 a1 1c 21\n        00 00 1e 8c 0a d0 8a 20 e0 2d 10 10 3e 96 00 a1\n        1c 21 00 00 18 8c 0a d0 90 20 40 31 20 0c 40 55\n        00 a1 1c 21 00 00 18 00 00 00 00 00 00 00 00 00\n        00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 ef\n        "
        ),
        EDIDOption(
            id: "E1024x768AOC",
            label: "1024x768/AOC/60Hz",
            edid: "00 ff ff ff ff ff ff 00 05 e3 22 a5 f3 2f 0e 00\n        23 12 01 03 80 1e 17 82 2a 8f 3d a4 58 4d 90 24\n        15 4f 51 bf ee 00 01 01 01 01 01 01 01 01 01 01\n        01 01 01 01 01 01 64 19 00 40 41 00 26 30 18 88\n        36 00 30 e4 10 00 00 18 00 00 00 ff 00 54 35 43\n        53 38 38 41 39 32 39 37 37 39 00 00 00 fd 00 37\n        4b 1e 3f 08 00 0a 20 20 20 20 20 20 00 00 00 fc\n        00 4c 4d 35 32 32 0a 20 20 20 20 20 20 20 01 0b\n\n        02 03 1b 61 23 09 07 07 83 01 00 00 67 03 0c 00\n        20 00 80 2d 43 90 84 02 e2 00 0f 8c 0a d0 8a 20\n        e0 2d 10 10 3e 96 00 a0 5a 00 00 00 00 00 00 00\n        00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00\n        00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00\n        00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00\n        00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00\n        00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 29\n        "
        ),
        EDIDOption(
            id: "E800x600CHR",
            label: "800x600/CHR/60Hz",
            edid: "00 ff ff ff ff ff ff 00 0d 12 11 75 70 03 00 00\n        05 17 01 04 95 2b 1d 78 e2 80 42 ac 51 30 b4 25\n        10 50 53 00 00 00 01 01 01 01 01 01 01 01 01 01\n        01 01 01 01 01 01 f1 0e 20 e0 30 58 18 20 20 50\n        34 00 07 44 21 00 00 1c 00 00 00 00 00 00 00 00\n        00 00 00 00 00 00 00 00 00 00 00 00 00 fd 00 38\n        4c 1e 53 11 00 0a 20 20 20 20 20 20 00 00 00 fc\n        00 43 48 37 35 31 31 42 0a 20 20 20 20 20 00 12\n        "
        ),
        EDIDOption(id: "CUSTOMIZE", label: "Custom", edid: nil),
    ]

    private let edidOverrides: [String: String] = [
        "E3840x2160": "00 ff ff ff ff ff ff 00 32 8d 32 31 00 88 88 88\n        20 1e 01 03 80 0c 07 78 0a 0d c9 a0 57 47 98 27\n        12 48 4c 00 00 00 01 01 01 01 01 01 01 01 01 01\n        01 01 01 01 01 01 04 74 00 30 f2 70 5a 80 b0 58\n        8a 00 00 70 f8 00 00 1e 02 3a 80 18 71 38 2d 40\n        58 2c 45 00 c4 8e 21 00 00 1e 00 00 00 fd 00 18\n        64 14 96 1e 00 0a 20 20 20 20 20 20 00 00 00 fc\n        00 4c 6f 6e 74 69 75 6d 20 73 65 6d 69 0a 01 64\n\n        02 03 1d f0 4a 01 04 10 1f 20 21 22 5d 5e 5f 23\n        09 04 01 83 01 00 00 65 03 0c 00 10 00 00 00 00\n        00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00\n        00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00\n        00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00\n        00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00\n        00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00\n        00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 ba",
        "E1920x1080": "00 ff ff ff ff ff ff 00 06 b3 b2 24 01 01 01 01\n        21 1e 01 03 80 35 1e 78 0e ee 91 a3 54 4c 99 26\n        0f 50 54 21 08 00 01 01 01 01 01 01 01 01 01 01\n        01 01 01 01 01 01 02 3a 80 18 71 38 2d 40 58 2c\n        45 00 13 2b 21 00 00 1e 00 00 00 ff 00 4c 38 4c\n        4d 51 53 30 37 35 33 39 32 20 00 00 00 fd 00 18\n        3c 1e 5a 1e 01 0a 20 20 20 20 20 20 00 00 00 fc\n        00 52 4f 47 20 50 47 32 34 38 51 0a 20 20 01 99\n\n        02 03 1a c1 47 90 1f 04 13 03 12 01 23 09 07 01\n        83 01 00 00 65 03 0c 00 10 00 00 00 00 00 00 00\n        00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00\n        00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00\n        00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00\n        00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00\n        00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00\n        00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 c1",
        "E1920x1200": "00 ff ff ff ff ff ff 00 4c a3 0b a7 01 01 01 01\n        08 1a 01 03 80 00 00 78 0a de 50 a3 54 4c 99 26\n        0f 50 54 a1 08 00 81 40 81 c0 95 00 81 80 90 40\n        b3 00 a9 40 01 01 28 3c 80 a0 70 b0 23 40 30 20\n        36 00 40 84 63 00 00 1a 9e 20 00 90 51 20 1f 30\n        48 80 36 00 40 84 63 00 00 1c 00 00 00 fd 00 17\n        55 0f 5c 11 00 0a 20 20 20 20 20 20 00 00 00 fc\n        00 45 50 53 4f 4e 20 50 4a 0a 20 20 20 20 01 15\n\n        02 03 28 f1 51 90 1f 20 22 05 14 04 13 03 02 12\n        11 07 06 16 15 01 23 09 07 07 83 01 00 00 66 03\n        0c 00 20 00 80 e2 00 fb 02 3a 80 18 71 38 2d 40\n        58 2c 45 00 40 84 63 00 00 1e 01 1d 80 18 71 38\n        2d 40 58 2c 45 00 40 84 63 00 00 1e 66 21 56 aa\n        51 00 1e 30 46 8f 33 00 40 84 63 00 00 1e 30 2a\n        40 c8 60 84 64 30 18 50 13 00 40 84 63 00 00 1e\n        00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 80",
        "E1920x1280": "00 ff ff ff ff ff ff 00 06 af 8d 93 00 00 00 00\n        0f 20 01 04 a5 1a 11 78 03 24 45 9b 53 4c 8e 27\n        16 50 54 00 00 00 01 01 01 01 01 01 01 01 01 01\n        01 01 01 01 01 01 62 3e 80 64 70 00 26 50 28 10\n        66 00 05 ae 10 00 00 18 00 00 00 fd 00 30 3c 50\n        50 10 00 00 00 00 00 00 00 20 00 00 00 fe 00 47\n        31 32 34 55 41 4e 30 31 2e 30 00 00 00 00 00 fe\n        00 52 51 39 33 48 32 46 57 37 44 33 34 00 00 ef",
        "E2560x1440VS": "00 ff ff ff ff ff ff 00 5a 63 34 2f ea 50 00 00\n        24 1e 01 03 80 35 1e 78 2e ff d5 a9 53 45 a0 25\n        0d 50 54 bf ef 80 d1 c0 b3 00 a9 40 a9 c0 95 00\n        90 40 81 80 81 c0 56 5e 00 a0 a0 a0 29 50 30 20\n        35 00 0f 28 21 00 00 1a 00 00 00 fd 00 32 4c 1e\n        53 1e 00 0a 20 20 20 20 20 20 00 00 00 fc 00 56\n        58 32 34 37 38 2d 32 0a 20 20 20 20 00 00 00 ff\n        00 55 59 4c 32 30 33 36 32 30 37 31 34 0a 01 ea\n\n        02 03 24 f1 4f 90 05 04 03 02 07 12 13 14 16 1f\n        20 21 22 01 23 09 7f 07 83 01 00 00 67 03 0c 00\n        10 00 20 40 02 3a 80 18 71 38 2d 40 58 2c 45 00\n        0f 28 21 00 00 1e 01 1d 80 18 71 1c 16 20 58 2c\n        25 00 0f 28 21 00 00 9e 01 1d 00 72 51 d0 1e 20\n        6e 28 55 00 0f 28 21 00 00 1e 02 3a 80 d0 72 38\n        2d 40 10 2c 45 80 0f 28 21 00 00 1e 01 1d 80 d0\n        72 1c 16 20 10 2c 25 80 0f 28 21 00 00 9e 00 50",
        "E1600x1200": "00 ff ff ff ff ff ff 00 5c 23 14 10 76 01 00 00\n        21 12 01 03 81 2c 21 78 aa a5 d5 a6 54 4a 9c 23\n        14 50 54 bf ef 00 31 59 45 59 61 59 81 80 81 99\n        a9 40 01 01 01 01 48 3f 40 30 62 b0 32 40 40 c0\n        13 00 b0 44 11 00 00 1e 00 00 00 fd 00 38 55 1f\n        5c 11 00 0a 20 20 20 20 20 20 00 00 00 ff 00 38\n        48 43 30 30 30 33 37 34 20 20 20 20 00 00 00 fc\n        00 43 69 6e 74 69 71 32 31 55 58 0a 20 20 00 39",
    ]

    private func resolvedEdid(for option: EDIDOption) -> String? {
        edidOverrides[option.id] ?? option.edid
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Settings")
                    .font(.headline)
                Spacer()
                if isLoading || isApplying || isApplyingEdid {
                    ProgressView()
                        .controlSize(.small)
                }
                if isApplyingStreamer {
                    ProgressView()
                        .controlSize(.small)
                }
                Button(action: { withAnimation(.easeInOut(duration: 0.2)) { isPresented = false } }) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    DisclosureGroup("Video", isExpanded: $isVideoExpanded) {
                        VStack(alignment: .leading, spacing: 10) {
                            Picker("Mode", selection: bindingString(
                                get: { $0.videoProcessing },
                                set: { $0.videoProcessing = $1 },
                                defaultValue: "low_latency_first"
                            )) {
                                ForEach(processingOptions, id: \.0) { value, label in
                                    Text(label).tag(value)
                                }
                            }

                            Picker("Quality", selection: $selectedVideoQualityPreset) {
                                Text("Low").tag(0)
                                Text("Medium").tag(1)
                                Text("High").tag(2)
                                Text("Ultra-high").tag(3)
                                Text("Insane").tag(videoQualityInsaneTag)
                                Text("Custom").tag(videoQualityCustomTag)
                            }
                            .disabled(kvmDeviceManager.glkvmClient == nil || isLoading || isApplying || isApplyingStreamer || isApplyingEdid)
                            .onChange(of: selectedVideoQualityPreset) { _, newValue in
                                guard isLoading == false else { return }
                                Task { await applyVideoQualityPreset(newValue) }
                            }

                            Picker("EDID", selection: $selectedEdidOption) {
                                ForEach(edidOptions, id: \.id) { opt in
                                    Text(opt.label).tag(opt.id)
                                }
                            }
                            .disabled(kvmDeviceManager.glkvmClient == nil || isLoading || isApplyingEdid)
                            .onChange(of: selectedEdidOption) { _, newValue in
                                guard isProgrammaticEdidSelectionUpdate == false else { return }
                                guard newValue != "CUSTOMIZE" else { return }
                                guard let opt = edidOptions.first(where: { $0.id == newValue }), let edid = resolvedEdid(for: opt) else { return }
                                Task { await applyEdid(edid) }
                            }

                            if selectedEdidOption == "CUSTOMIZE" {
                                TextEditor(text: $customEdidDraft)
                                    .font(.body)
                                    .frame(minHeight: 90, maxHeight: 160)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                                    )
                                    .disabled(kvmDeviceManager.glkvmClient == nil || isApplyingEdid)

                                HStack {
                                    Button("Apply custom EDID") {
                                        Task { await applyEdid(customEdidDraft) }
                                    }
                                    .disabled(
                                        kvmDeviceManager.glkvmClient == nil ||
                                            isApplyingEdid ||
                                            customEdidDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    )

                                    Spacer()
                                }
                            }

                            Picker("Orientation", selection: bindingInt(
                                get: { $0.orientation },
                                set: { $0.orientation = $1 },
                                defaultValue: 0
                            )) {
                                Text("0°").tag(0)
                                Text("90°").tag(90)
                                Text("180°").tag(180)
                                Text("270°").tag(270)
                            }

                            Toggle("Show Cursor", isOn: bindingBool(
                                get: { $0.showCursor },
                                set: { $0.showCursor = $1 },
                                defaultValue: true
                            ))

                            if selectedVideoQualityPreset == videoQualityCustomTag {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Streamer")
                                        .font(.subheadline)

                                    HStack {
                                        Text("FPS")
                                        Spacer()
                                        TextField("", text: $streamerDesiredFpsText)
                                            .frame(width: 70)
                                            .textFieldStyle(.roundedBorder)
                                            .multilineTextAlignment(.trailing)
                                            .focused($focusedStreamerField, equals: .fps)
                                            .onSubmit {
                                                focusedStreamerField = nil
                                            }
                                        Stepper(
                                            "",
                                            value: $streamerDesiredFps,
                                            in: (streamerLimits?.desiredFps.min ?? 1)...(streamerLimits?.desiredFps.max ?? 60)
                                        )
                                        .labelsHidden()
                                        .disabled(focusedStreamerField == .fps)
                                    }
                                    .disabled(streamerState == nil)
                                    .onChange(of: streamerDesiredFps) { _, _ in
                                        guard isProgrammaticStreamerDraftUpdate == false else { return }
                                        streamerDesiredFpsText = String(streamerDesiredFps)
                                        scheduleStreamerApply()
                                    }

                                    HStack {
                                        Text("Quality")
                                        Spacer()
                                        TextField("", text: $streamerQualityText)
                                            .frame(width: 70)
                                            .textFieldStyle(.roundedBorder)
                                            .multilineTextAlignment(.trailing)
                                            .focused($focusedStreamerField, equals: .quality)
                                            .onSubmit {
                                                focusedStreamerField = nil
                                            }
                                        Stepper("", value: $streamerQuality, in: 0...100)
                                            .labelsHidden()
                                            .disabled(focusedStreamerField == .quality)
                                    }
                                    .disabled(streamerState == nil || streamerFeatures?.quality == false)
                                    .onChange(of: streamerQuality) { _, _ in
                                        guard isProgrammaticStreamerDraftUpdate == false else { return }
                                        streamerQualityText = String(streamerQuality)
                                        scheduleStreamerApply()
                                    }

                                HStack {
                                    Text("Bitrate")
                                    Spacer()
                                    TextField("", text: $streamerH264BitrateText)
                                        .frame(width: 90)
                                        .textFieldStyle(.roundedBorder)
                                        .multilineTextAlignment(.trailing)
                                        .focused($focusedStreamerField, equals: .bitrate)
                                        .onSubmit {
                                            focusedStreamerField = nil
                                        }
                                    Stepper(
                                        "",
                                        value: $streamerH264Bitrate,
                                        in: (streamerLimits?.h264Bitrate.min ?? 100)...(streamerLimits?.h264Bitrate.max ?? 20000)
                                    )
                                    .labelsHidden()
                                    .disabled(focusedStreamerField == .bitrate)
                                }
                                .disabled(streamerState == nil || streamerFeatures?.h264 == false)
                                .onChange(of: streamerH264Bitrate) { _, _ in
                                    guard isProgrammaticStreamerDraftUpdate == false else { return }
                                    streamerH264BitrateText = String(streamerH264Bitrate)
                                    scheduleStreamerApply()
                                }

                                HStack {
                                    Text("GOP")
                                    Spacer()
                                    TextField("", text: $streamerH264GopText)
                                        .frame(width: 70)
                                        .textFieldStyle(.roundedBorder)
                                        .multilineTextAlignment(.trailing)
                                        .focused($focusedStreamerField, equals: .gop)
                                        .onSubmit {
                                            focusedStreamerField = nil
                                        }
                                    Stepper(
                                        "",
                                        value: $streamerH264Gop,
                                        in: (streamerLimits?.h264Gop.min ?? 1)...(streamerLimits?.h264Gop.max ?? 300)
                                    )
                                    .labelsHidden()
                                    .disabled(focusedStreamerField == .gop)
                                }
                                .disabled(streamerState == nil || streamerFeatures?.h264 == false)
                                .onChange(of: streamerH264Gop) { _, _ in
                                    guard isProgrammaticStreamerDraftUpdate == false else { return }
                                    streamerH264GopText = String(streamerH264Gop)
                                    scheduleStreamerApply()
                                }

                                    Toggle("Zero delay", isOn: $streamerZeroDelay)
                                        .disabled(streamerState == nil || streamerFeatures?.zeroDelay == false)
                                        .onChange(of: streamerZeroDelay) { _, _ in
                                            guard isProgrammaticStreamerDraftUpdate == false else { return }
                                            scheduleStreamerApply()
                                        }

                                Picker("Resolution", selection: streamerResolutionSelection) {
                                    Text("Auto").tag("")
                                    Text("1920x1080").tag("1920x1080")
                                    Text("1600x900").tag("1600x900")
                                    Text("1280x720").tag("1280x720")
                                    Text("1024x768").tag("1024x768")
                                    Text("Custom").tag("custom")
                                }
                                .disabled(streamerState == nil || streamerFeatures?.resolution == false)

                                if streamerResolutionSelection.wrappedValue == "custom" {
                                    TextField("Custom resolution (e.g. 1920x1080)", text: $streamerResolution)
                                        .textFieldStyle(.roundedBorder)
                                        .disabled(streamerState == nil || streamerFeatures?.resolution == false)
                                        .onChange(of: streamerResolution) { _, _ in
                                            guard isProgrammaticStreamerDraftUpdate == false else { return }
                                            guard focusedStreamerField == nil else { return }
                                            scheduleStreamerApply()
                                        }
                                        .focused($focusedStreamerField, equals: .resolution)
                                        .onSubmit {
                                            focusedStreamerField = nil
                                        }
                                }
                                }
                                .onChange(of: focusedStreamerField) { old, new in
                                    if old != nil, new == nil {
                                        commitStreamerEditsAndApplyIfNeeded()
                                    }
                                }
                            }
                        }
                        .padding(.top, 6)
                    }

                    DisclosureGroup("Remote device settings", isExpanded: $isRemoteExpanded) {
                        VStack(alignment: .leading, spacing: 10) {
                            Toggle("Mouse Control", isOn: bindingBool(
                                get: { $0.mouseControl },
                                set: { $0.mouseControl = $1 },
                                defaultValue: true
                            ))

                            Toggle("Keyboard Control", isOn: bindingBool(
                                get: { $0.keyboardControl },
                                set: { $0.keyboardControl = $1 },
                                defaultValue: true
                            ))

                            HStack {
                                Text("Mouse Polling")
                                Spacer()
                                let polling = bindingInt(
                                    get: { $0.mousePolling },
                                    set: { $0.mousePolling = $1 },
                                    defaultValue: 10
                                )
                                TextField("", value: polling, formatter: integerFormatter)
                                    .frame(width: 70)
                                    .textFieldStyle(.roundedBorder)
                                    .multilineTextAlignment(.trailing)
                                Stepper("", value: polling, in: 1...60)
                                    .labelsHidden()
                            }

                            HStack {
                                Text("Sensitivity")
                                Spacer()
                                let sensitivity = bindingInt(
                                    get: { $0.relativeSense },
                                    set: { $0.relativeSense = $1 },
                                    defaultValue: 10
                                )
                                TextField("", value: sensitivity, formatter: integerFormatter)
                                    .frame(width: 70)
                                    .textFieldStyle(.roundedBorder)
                                    .multilineTextAlignment(.trailing)
                                Stepper("", value: sensitivity, in: 1...60)
                                    .labelsHidden()
                            }

                            HStack {
                                Text("Scroll rate")
                                Spacer()
                                let scrollRate = bindingInt(
                                    get: { $0.scrollRate },
                                    set: { $0.scrollRate = $1 },
                                    defaultValue: 5
                                )
                                TextField("", value: scrollRate, formatter: integerFormatter)
                                    .frame(width: 70)
                                    .textFieldStyle(.roundedBorder)
                                    .multilineTextAlignment(.trailing)
                                Stepper("", value: scrollRate, in: 1...30)
                                    .labelsHidden()
                            }

                            Picker("Scroll direction", selection: bindingString(
                                get: { $0.reverseScrolling },
                                set: { $0.reverseScrolling = $1 },
                                defaultValue: "STANDARD"
                            )) {
                                ForEach(reverseScrollingOptions, id: \.0) { value, label in
                                    Text(label).tag(value)
                                }
                            }

                            Toggle("Mouse Jiggle", isOn: bindingBool(
                                get: { $0.mouseJiggle },
                                set: { $0.mouseJiggle = $1 },
                                defaultValue: false
                            ))

                            Picker("Mouse mode", selection: bindingBool(
                                get: { $0.isAbsoluteMouse },
                                set: { $0.isAbsoluteMouse = $1 },
                                defaultValue: true
                            )) {
                                Text("Relative").tag(false)
                                Text("Absolute").tag(true)
                            }

                            Stepper(
                                "Fingerbot strength: \(bindingIntValue(get: { $0.fingerbotStrength }, defaultValue: 0))",
                                value: bindingInt(
                                    get: { $0.fingerbotStrength },
                                    set: { $0.fingerbotStrength = $1 },
                                    defaultValue: 0
                                ),
                                in: 0...100
                            )
                        }
                        .padding(.top, 6)
                    }

                    DisclosureGroup("Keyboard settings", isExpanded: $isKeyboardExpanded) {
                        VStack(alignment: .leading, spacing: 10) {
                            Picker("Keymap", selection: bindingString(
                                get: { $0.keymap },
                                set: { $0.keymap = $1 },
                                defaultValue: "en-us"
                            )) {
                                ForEach(availableKeymaps(), id: \.self) { keymap in
                                    Text(keymap).tag(keymap)
                                }
                            }

                            if let shortcuts = config?.shortcuts, !shortcuts.isEmpty {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Shortcuts")
                                        .font(.subheadline)

                                    ForEach(shortcuts, id: \.self) { shortcut in
                                        HStack(alignment: .firstTextBaseline) {
                                            Text(shortcut.label)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                            Text(shortcut.keys.joined(separator: "+"))
                                                .foregroundColor(.secondary)
                                                .font(.caption)
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.top, 6)
                    }

                    DisclosureGroup("Audio", isExpanded: $isAudioExpanded) {
                        VStack(alignment: .leading, spacing: 10) {
                            Toggle("Audio", isOn: $webRTCManager.audioEnabled)
                            Toggle("Microphone", isOn: $webRTCManager.micEnabled)

                            Picker("Microphone device", selection: $audioInputDeviceUID) {
                                Text("System Default").tag("")
                                if !audioInputDeviceUID.isEmpty,
                                   audioInputDevices.contains(where: { $0.uid == audioInputDeviceUID }) == false {
                                    Text("Unavailable").tag(audioInputDeviceUID)
                                }
                                ForEach(audioInputDevices, id: \.uid) { device in
                                    Text(device.name).tag(device.uid)
                                }
                            }

                            Picker("Output device", selection: $audioOutputDeviceUID) {
                                Text("System Default").tag("")
                                if !audioOutputDeviceUID.isEmpty,
                                   audioOutputDevices.contains(where: { $0.uid == audioOutputDeviceUID }) == false {
                                    Text("Unavailable").tag(audioOutputDeviceUID)
                                }
                                ForEach(audioOutputDevices, id: \.uid) { device in
                                    Text(device.name).tag(device.uid)
                                }
                            }

                            Text("Reconnect required")
                                .foregroundColor(.secondary)
                                .font(.caption)

                            Button("Reconnect WebRTC") {
                                Task { await reconnectWebRTC() }
                            }
                            .disabled(kvmDeviceManager.connectedDevice == nil)
                        }
                        .padding(.top, 6)
                        .onAppear { refreshAudioDevices() }
                        .onChange(of: isAudioExpanded) { _, _ in refreshAudioDevices() }
                    }

                    DisclosureGroup("System", isExpanded: $isSystemExpanded) {
                        VStack(alignment: .leading, spacing: 10) {
                            Picker("App appearance", selection: $appAppearance) {
                                ForEach(appAppearanceOptions, id: \.0) { value, label in
                                    Text(label).tag(value)
                                }
                            }

                            Picker("Color mode", selection: bindingString(
                                get: { $0.themeMode },
                                set: { $0.themeMode = $1 },
                                defaultValue: "0"
                            )) {
                                ForEach(themeOptions, id: \.0) { value, label in
                                    Text(label).tag(value)
                                }
                            }

                            NotImplementedRow(title: "Language")
                            NotImplementedRow(title: "Timezone")
                        }
                        .padding(.top, 6)
                    }

                    DisclosureGroup("Network", isExpanded: $isNetworkExpanded) {
                        VStack(alignment: .leading, spacing: 10) {
                            NotImplementedRow(title: "Modify")
                            NotImplementedRow(title: "Wi-Fi")
                            NotImplementedRow(title: "Ethernet")
                        }
                        .padding(.top, 6)
                    }

                    DisclosureGroup("Advanced", isExpanded: $isAdvancedExpanded) {
                        VStack(alignment: .leading, spacing: 10) {
                            Button("Reset KVM") {
                                Task { await resetKVM() }
                            }
                            .disabled(kvmDeviceManager.glkvmClient == nil)
                        }
                        .padding(.top, 6)
                    }
                }
                .padding()
            }

            Divider()

            if let errorMessage {
                VStack(alignment: .leading, spacing: 8) {
                    Text(errorMessage)
                        .foregroundColor(.red)
                        .font(.caption)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 10) {
                        Button("History…") {
                            showingErrorHistory = true
                        }
                        .buttonStyle(.borderless)

                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(errorMessage, forType: .string)
                        }
                        .buttonStyle(.borderless)

                        Button("Dismiss") {
                            self.errorMessage = nil
                        }
                        .buttonStyle(.borderless)

                        Spacer()
                    }
                    .font(.caption)
                }
                .padding(.horizontal)
                .padding(.vertical, 10)
            }
        }
        .background(panelBackground)
        .sheet(isPresented: $showingErrorHistory) {
            ErrorHistorySheet(entries: errorHistory)
        }
        .task(id: isPresented) {
            guard isPresented else { return }
            await load()
        }
    }

    private func applyVideoQualityPreset(_ preset: Int) async {
        guard preset != videoQualityCustomTag else { return }
        guard let client = kvmDeviceManager.glkvmClient else { return }

        var params: [String: String] = [:]
        var streamQuality: Int? = nil

        switch preset {
        case 0:
            params = ["h264_bitrate": "500", "h264_gop": "30"]
            streamQuality = 0
        case 1:
            params = ["h264_bitrate": "2000", "h264_gop": "30"]
            streamQuality = 1
        case 2:
            params = ["h264_bitrate": "5000", "h264_gop": "60"]
            streamQuality = 2
        case 3:
            params = ["h264_bitrate": "8000", "h264_gop": "60"]
            streamQuality = 3
        case videoQualityInsaneTag:
            params = ["quality": "100", "h264_bitrate": "20000", "h264_gop": "60"]
            streamQuality = 3
        default:
            return
        }

        await MainActor.run {
            isApplyingStreamer = true
        }

        do {
            try await client.setStreamerParams(params)
            try? await Task.sleep(nanoseconds: 300_000_000)
            let st = try? await client.getStreamerState()
            await MainActor.run {
                streamerState = st
                syncStreamerDraft(from: st)
            }
        } catch {
            await MainActor.run {
                recordError("Failed to apply quality preset: \(error)")
            }
        }

        await MainActor.run {
            isApplyingStreamer = false
            if let streamQuality {
                updateConfig { $0.streamQuality = streamQuality }
            }
        }
    }

    private struct ErrorHistorySheet: View {
        let entries: [ErrorEntry]

        private static let dateFormatter: DateFormatter = {
            let df = DateFormatter()
            df.dateStyle = .short
            df.timeStyle = .medium
            return df
        }()

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Errors")
                        .font(.headline)
                    Spacer()
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(entries) { entry in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(Self.dateFormatter.string(from: entry.date))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text(entry.message)
                                    .font(.caption)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Divider()
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 10)
                }

                HStack {
                    Button("Copy Latest") {
                        if let latest = entries.first?.message {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(latest, forType: .string)
                        }
                    }
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.bottom, 10)
            }
            .frame(minWidth: 520, minHeight: 360)
        }
    }

    @MainActor
    private func recordError(_ message: String) {
        errorMessage = message
        errorHistory.insert(ErrorEntry(date: Date(), message: message), at: 0)
        if errorHistory.count > 50 {
            errorHistory.removeLast(errorHistory.count - 50)
        }
    }

    private func availableKeymaps() -> [String] {
        if let keymaps {
            let list = keymaps.keymaps.available
            if let current = config?.keymap, !current.isEmpty, !list.contains(current) {
                return [current] + list
            }
            return list
        }
        if let current = config?.keymap, !current.isEmpty {
            return [current]
        }
        return ["en-us"]
    }

    private func load() async {
        guard let client = kvmDeviceManager.glkvmClient else {
            await MainActor.run {
                config = nil
                keymaps = nil
                streamerState = nil
                currentEdid = ""
                selectedEdidOption = "CUSTOMIZE"
                customEdidDraft = ""
                selectedVideoQualityPreset = 1
            }
            return
        }
        await MainActor.run {
            isLoading = true
        }
        do {
            async let keymaps = client.getHidKeymaps()
            async let streamer = client.getStreamerState()
            let config = try await client.getSystemConfig()
            let km = try await keymaps
            let st = try await streamer
            let edidValue = try await client.getEDID()
            await MainActor.run {
                self.config = config
                self.keymaps = km
                self.streamerState = st
                self.currentEdid = edidValue
                syncEdidSelectionFromCurrent()
                if let params = st.params,
                   params.h264Bitrate == 20000,
                   params.h264Gop == 60,
                   params.quality == 100 {
                    selectedVideoQualityPreset = videoQualityInsaneTag
                } else if (0...3).contains(config.streamQuality) {
                    selectedVideoQualityPreset = config.streamQuality
                } else {
                    selectedVideoQualityPreset = videoQualityCustomTag
                }
                syncStreamerDraft(from: st)
                isLoading = false
            }
        } catch {
            await MainActor.run {
                isLoading = false
                recordError("Failed to load settings: \(error)")
            }
        }
    }

    private func normalizedEdid(_ value: String) -> String {
        value
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
            .lowercased()
    }

    @MainActor
    private func syncEdidSelectionFromCurrent() {
        isProgrammaticEdidSelectionUpdate = true
        defer {
            Task { @MainActor in
                await Task.yield()
                isProgrammaticEdidSelectionUpdate = false
            }
        }

        let normalizedCurrent = normalizedEdid(currentEdid)
        if normalizedCurrent.isEmpty {
            selectedEdidOption = "CUSTOMIZE"
            customEdidDraft = ""
            return
        }

        if let match = edidOptions.first(where: { opt in
            guard let edid = resolvedEdid(for: opt) else { return false }
            return normalizedEdid(edid) == normalizedCurrent
        }) {
            selectedEdidOption = match.id
            customEdidDraft = currentEdid
            return
        }

        selectedEdidOption = "CUSTOMIZE"
        customEdidDraft = currentEdid
    }

    @MainActor
    private func applyEdid(_ value: String) async {
        guard let client = kvmDeviceManager.glkvmClient else { return }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isApplyingEdid = true

        do {
            try await client.setEDID(trimmed)
            let updated = try await client.getEDID()
            currentEdid = updated
            syncEdidSelectionFromCurrent()
            isApplyingEdid = false
        } catch {
            isApplyingEdid = false
            recordError("Failed to apply EDID: \(error)")
        }
    }

    @MainActor
    private func syncStreamerDraft(from state: GLKVMStreamerState?) {
        guard let params = state?.params else { return }

        if focusedStreamerField != nil { return }

        isProgrammaticStreamerDraftUpdate = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            isProgrammaticStreamerDraftUpdate = false
        }

        if let desiredFps = params.desiredFps { streamerDesiredFps = desiredFps }
        if let quality = params.quality { streamerQuality = quality }
        if let bitrate = params.h264Bitrate { streamerH264Bitrate = bitrate }
        if let gop = params.h264Gop { streamerH264Gop = gop }
        if let zeroDelay = params.zeroDelay { streamerZeroDelay = zeroDelay }
        if let resolution = params.resolution { streamerResolution = resolution }

        streamerDesiredFpsText = String(streamerDesiredFps)
        streamerQualityText = String(streamerQuality)
        streamerH264BitrateText = String(streamerH264Bitrate)
        streamerH264GopText = String(streamerH264Gop)
    }

    @MainActor
    private func scheduleStreamerApply() {
        guard isProgrammaticStreamerDraftUpdate == false else { return }
        applyStreamerTask?.cancel()
        applyStreamerTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            await applyStreamerParams()
        }
    }

    @MainActor
    private func applyStreamerParams() async {
        guard let client = kvmDeviceManager.glkvmClient else { return }
        guard streamerState != nil else { return }

        guard isProgrammaticStreamerDraftUpdate == false else { return }

        isApplyingStreamer = true

        let features = streamerFeatures

        let desiredFpsMin = streamerLimits?.desiredFps.min ?? 1
        let desiredFpsMax = streamerLimits?.desiredFps.max ?? 60
        let bitrateMin = streamerLimits?.h264Bitrate.min ?? 100
        let bitrateMax = streamerLimits?.h264Bitrate.max ?? 20000
        let gopMin = streamerLimits?.h264Gop.min ?? 1
        let gopMax = streamerLimits?.h264Gop.max ?? 300

        let clampedFps = clamp(streamerDesiredFps, min: desiredFpsMin, max: desiredFpsMax)
        let clampedQuality = clamp(streamerQuality, min: 0, max: 100)
        let clampedBitrate = clamp(streamerH264Bitrate, min: bitrateMin, max: bitrateMax)
        let clampedGop = clamp(streamerH264Gop, min: gopMin, max: gopMax)

        var params: [String: String] = [:]
        params["desired_fps"] = String(clampedFps)

        if features?.quality != false {
            params["quality"] = String(clampedQuality)
        }

        if features?.h264 != false {
            params["h264_bitrate"] = String(clampedBitrate)
            params["h264_gop"] = String(clampedGop)
        }

        if features?.zeroDelay != false {
            params["zero_delay"] = streamerZeroDelay ? "true" : "false"
        }

        if features?.resolution != false {
            let trimmed = streamerResolution.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                params["resolution"] = trimmed
            }
        }

        do {
            try await client.setStreamerParams(params)
            try? await Task.sleep(nanoseconds: 300_000_000)
            let st = try? await client.getStreamerState()
            streamerState = st
            syncStreamerDraft(from: st)
            isApplyingStreamer = false
        } catch {
            isApplyingStreamer = false
            recordError("Failed to apply streamer params: \(error)")
        }
    }

    @MainActor
    private func commitStreamerEditsAndApplyIfNeeded() {
        guard isProgrammaticStreamerDraftUpdate == false else { return }

        isProgrammaticStreamerDraftUpdate = true
        defer {
            Task { @MainActor in
                await Task.yield()
                isProgrammaticStreamerDraftUpdate = false
            }
        }

        let desiredFpsMin = streamerLimits?.desiredFps.min ?? 1
        let desiredFpsMax = streamerLimits?.desiredFps.max ?? 60
        let bitrateMin = streamerLimits?.h264Bitrate.min ?? 100
        let bitrateMax = streamerLimits?.h264Bitrate.max ?? 20000
        let gopMin = streamerLimits?.h264Gop.min ?? 1
        let gopMax = streamerLimits?.h264Gop.max ?? 300

        let parsedFps = Int(streamerDesiredFpsText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? streamerDesiredFps
        let parsedQuality = Int(streamerQualityText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? streamerQuality
        let parsedBitrate = Int(streamerH264BitrateText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? streamerH264Bitrate
        let parsedGop = Int(streamerH264GopText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? streamerH264Gop

        let nextFps = clamp(parsedFps, min: desiredFpsMin, max: desiredFpsMax)
        let nextQuality = clamp(parsedQuality, min: 0, max: 100)
        let nextBitrate = clamp(parsedBitrate, min: bitrateMin, max: bitrateMax)
        let nextGop = clamp(parsedGop, min: gopMin, max: gopMax)

        if nextFps != streamerDesiredFps { streamerDesiredFps = nextFps }
        if nextQuality != streamerQuality { streamerQuality = nextQuality }
        if nextBitrate != streamerH264Bitrate { streamerH264Bitrate = nextBitrate }
        if nextGop != streamerH264Gop { streamerH264Gop = nextGop }

        streamerDesiredFpsText = String(streamerDesiredFps)
        streamerQualityText = String(streamerQuality)
        streamerH264BitrateText = String(streamerH264Bitrate)
        streamerH264GopText = String(streamerH264Gop)

        // Apply once after commit.
        Task { @MainActor in
            await Task.yield()
            scheduleStreamerApply()
        }
    }

    private var streamerResolutionSelection: Binding<String> {
        Binding(
            get: {
                let trimmed = streamerResolution.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { return "" }
                let presets: Set<String> = ["1920x1080", "1600x900", "1280x720", "1024x768"]
                if presets.contains(trimmed) {
                    return trimmed
                }
                return "custom"
            },
            set: { newValue in
                if newValue == "custom" {
                    return
                }
                streamerResolution = newValue
                scheduleStreamerApply()
            }
        )
    }

    private func clamp(_ value: Int, min: Int, max: Int) -> Int {
        if value < min { return min }
        if value > max { return max }
        return value
    }

    @MainActor
    private func refreshAudioDevices() {
        audioInputDevices = CoreAudioDevices.listInputDevices()
        audioOutputDevices = CoreAudioDevices.listOutputDevices()
    }

    @MainActor
    private func reconnectWebRTC() async {
        guard let device = kvmDeviceManager.connectedDevice else { return }

        webRTCManager.disconnect()

        do {
            try await webRTCManager.connect(to: device)
        } catch {
            await MainActor.run {
                recordError("Failed to reconnect WebRTC: \(error)")
            }
        }
    }

    private func updateConfig(_ mutate: (inout GLKVMSystemConfig) -> Void) {
        guard var config else { return }
        mutate(&config)
        self.config = config
        scheduleApply(config)
    }

    private func scheduleApply(_ config: GLKVMSystemConfig) {
        applyTask?.cancel()
        applyTask = Task {
            try? await Task.sleep(nanoseconds: 150_000_000)
            await apply(config)
        }
    }

    private func apply(_ config: GLKVMSystemConfig) async {
        guard let client = kvmDeviceManager.glkvmClient else { return }
        await MainActor.run { isApplying = true }
        do {
            let updated = try await client.setSystemConfig(config)
            await MainActor.run {
                self.config = updated
                isApplying = false
            }
        } catch {
            await MainActor.run {
                isApplying = false
                recordError("Failed to apply settings: \(error)")
            }
        }
    }

    private func resetKVM() async {
        guard let client = kvmDeviceManager.glkvmClient else { return }
        do {
            try await client.resetHid()
            try await client.resetStreamer()
        } catch {
            await MainActor.run {
                recordError("Failed to reset: \(error)")
            }
        }
    }

    private func bindingString(
        get: @escaping (GLKVMSystemConfig) -> String,
        set: @escaping (inout GLKVMSystemConfig, String) -> Void,
        defaultValue: String
    ) -> Binding<String> {
        Binding(
            get: { config.map(get) ?? defaultValue },
            set: { newValue in
                guard config != nil, !isLoading, !isApplying else { return }
                updateConfig { set(&$0, newValue) }
            }
        )
    }

    private func bindingInt(
        get: @escaping (GLKVMSystemConfig) -> Int,
        set: @escaping (inout GLKVMSystemConfig, Int) -> Void,
        defaultValue: Int
    ) -> Binding<Int> {
        Binding(
            get: { config.map(get) ?? defaultValue },
            set: { newValue in
                guard config != nil, !isLoading, !isApplying else { return }
                updateConfig { set(&$0, newValue) }
            }
        )
    }

    private func bindingBool(
        get: @escaping (GLKVMSystemConfig) -> Bool,
        set: @escaping (inout GLKVMSystemConfig, Bool) -> Void,
        defaultValue: Bool
    ) -> Binding<Bool> {
        Binding(
            get: { config.map(get) ?? defaultValue },
            set: { newValue in
                guard config != nil, !isLoading, !isApplying else { return }
                updateConfig { set(&$0, newValue) }
            }
        )
    }

    private func bindingIntValue(get: @escaping (GLKVMSystemConfig) -> Int, defaultValue: Int) -> Int {
        config.map(get) ?? defaultValue
    }
}

private struct NotImplementedRow: View {
    let title: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text("Not implemented yet")
                .foregroundColor(.secondary)
                .font(.caption)
        }
        .opacity(0.7)
        .allowsHitTesting(false)
    }
}
