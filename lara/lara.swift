//
//  lara.swift
//  lara
//
//  Created by ruter on 23.03.26.
//
//  精简版：Tweaks 与文件管理器已移除，只保留漏洞利用、远程调用与全局悬浮·第一视角。
//

import SwiftUI
import UniformTypeIdentifiers
import Darwin

enum taboptions {
    case applying, clock, logs
}

let g_isunsupported: Bool = isunsupported()
var weonadebugbuild_pjbweouttahereexclamationmark: Bool = false

@main
struct lara: App {
    @StateObject private var mgr = laramgr.shared
    @Environment(\.scenePhase) var scenephase
    @AppStorage("keepAlive") private var keepalive: Bool = false
    @AppStorage("logsdisplaymode") private var logsdisplaymode: logsdisplaymode = .toolbar
    @State private var selectedtab: taboptions = .applying

    init() {
        #if DEBUG
        weonadebugbuild_pjbweouttahereexclamationmark = true
        #endif

        // 关键：忽略 SIGPIPE。Logger 把 stdout 接到管道上，切后台/重定向时若
        // 另一端被关掉，任何还在写日志的线程都会收到 SIGPIPE——默认动作是**直接
        // 杀死进程**，而且不留崩溃报告。lara 一死，SpringBoard 里挂着的木马线程
        // 就没人应答，裸崩在 PC=0x401 → 桌面重开。忽略 SIGPIPE 后写入只会返回
        // EPIPE，绝不致命。
        _ = signal(SIGPIPE, SIG_IGN)

        // fix file picker
        let fixMethod = class_getInstanceMethod(UIDocumentPickerViewController.self, #selector(UIDocumentPickerViewController.fix_init(forOpeningContentTypes:asCopy:)))!
        let origMethod = class_getInstanceMethod(UIDocumentPickerViewController.self, #selector(UIDocumentPickerViewController.init(forOpeningContentTypes:asCopy:)))!
        method_exchangeImplementations(origMethod, fixMethod)

        if keepalive {
            toggleka()
        }

        globallogger.capture()
    }

    var body: some Scene {
        WindowGroup {
            TabView(selection: $selectedtab) {
                ContentView()
                    .tabItem {
                        Image(systemName: "wrench.and.screwdriver.fill")
                    }
                    .tag(taboptions.applying)

                ClockView()
                    .tabItem {
                        Image(systemName: "clock.fill")
                    }
                    .tag(taboptions.clock)

                if logsdisplaymode == .tabs {
                    LogsView(logger: globallogger)
                        .tabItem {
                            Image(systemName: "terminal")
                        }
                        .tag(taboptions.logs)
                }
            }
            .environmentObject(mgr)
            .overlay {
                if mgr.showrespring {
                    respringview()
                        .brightness(-1.0)
                        .ignoresSafeArea()
                }
            }
            .sheet(isPresented: Binding(
                get: { logsdisplaymode == .toolbar && mgr.showLogs },
                set: { mgr.showLogs = $0 }
            )) {
                LogsView(logger: globallogger)
            }
            .onAppear {
                if !isunsupported() {
                    init_offsets()
                    offsets_init()
                    mgr.hasOffsets = emergencyfixfunctiontobereplacedlateronquestionmark()
                } else {
                    Alertinator.shared.alert(title: "此设备不受支持！", body: "非常抱歉，Lara 目前不支持此设备。可能的原因：\n- 你的 iOS 版本不受支持（支持的版本：iOS 16.0 - iOS 18.7.1、iOS 26.0 - iOS 26.0.1）\n- 你的设备具有 MIE（A19+ 或 M5+）\n- 已附加调试器。", actionLabel: "退出应用", action: { exitinator() })
                }
            }
            .onChange(of: scenephase, perform: handleScenePhase)
        }
    }

    private func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .inactive, .background:
            // 注意：这里【不要】再 globallogger.stopcapture()。切后台那一刻浮层/远程
            // 调用线程还在往 stdout 打印，(rc) 刷屏量极大；此时把日志管道拆掉，
            // 并发的 printf 会踩到已关闭的 fd。保留管道、持续采集，既避开这个竞态，
            // 也让日志能完整记录到崩溃前一刻。
            handlebg()

        case .active:
            globallogger.capture()
            // 回到前台：只有用户确实是「开」的状态才确保浮层在；用户主动关掉后
            // （fpvOn=false）不要再自动把它拉起来。
            if mgr.fpvOn && mgr.rcready && !mgr.clockrunning {
                mgr.startClock()
            }

        @unknown default:
            break
        }
    }

    private func handlebg() {
        guard mgr.rcready else { return }

        // 关键：SpringBoard 里的远程会话靠 lara 进程持续应答。lara 一旦被系统挂起，
        // 或者这个会话被拆掉，SpringBoard 里挂着的木马线程就没人应答、裸崩在
        // PC=0x401，于是**整个 SpringBoard 重开**——也就是"返回桌面就崩溃"。
        // 所以切后台【绝不拆会话】，改为打开后台保活（播放静音、走 audio 后台模式），
        // 让 lara 留在后台继续应答；浮层本来也要求 lara 活着才能更新。
        if !kaenabled {
            toggleka()
            UserDefaults.standard.set(true, forKey: "keepAlive")
            globallogger.log("(ka) 后台保活已开启：维持 SpringBoard 远程会话，不拆会话")
        } else {
            globallogger.log("(fpv) 后台保留远程会话（保活中）")
        }
    }

    private func endbgtask(_ task: inout UIBackgroundTaskIdentifier) {
        guard task != .invalid else { return }
        UIApplication.shared.endBackgroundTask(task)
        task = .invalid
    }
}

// file picker fixes
extension UIDocumentPickerViewController {
    @objc func fix_init(forOpeningContentTypes contentTypes: [UTType], asCopy: Bool) -> UIDocumentPickerViewController {
        return fix_init(forOpeningContentTypes: contentTypes, asCopy: true)
    }
}

// make strings compatiable with errors
extension String: @retroactive Error {}
