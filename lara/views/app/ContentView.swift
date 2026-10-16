//
//  ContentView.swift
//  lara
//
//  Created by ruter on 23.03.26.
//

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var mgr: laramgr
    @ObservedObject private var logger = globallogger
    @AppStorage("selectedMethod") private var selectedmethod: method = .hybrid
    @AppStorage("logsdisplaymode") private var selectedlogsdisplaymode: logsdisplaymode = .toolbar
    @AppStorage("loggerNoBS") private var loggernobs: Bool = true
    @State private var showSettings: Bool = false
    @State private var dlingkcache: Bool = false

    init() {
        globallogger.capture()
    }

    var body: some View {
        NavigationStack {
            List {
                AlertsSection
                KRWSection
                RCSection
                ActionsSection
                DebugSection
                InlineLogsSection
            }
            .navigationTitle("lara")
            .toolbar {
                if selectedlogsdisplaymode == .toolbar {
                    Button(action: { mgr.showLogs.toggle() }) {
                        Image(systemName: "terminal")
                    }
                }
                Button(action: { showSettings.toggle() }) {
                    Image(systemName: "gear")
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .onAppear {
                // 远程调用已就绪时自动显示悬浮时间
                if mgr.rcready && !mgr.clockrunning {
                    mgr.startClock()
                }
            }
        }
    }

    private var AlertsSection: some View {
        Section {
            if !mgr.hasOffsets {
                PlainAlert(title: "未找到偏移量！", icon: "exclamationmark.triangle.fill", text: "缺少内核缓存偏移量。请点击\"运行漏洞利用\"然后获取偏移量。")
            }
        }
    }

    private var KRWSection: some View {
        Section {
            LabeledContent(content: {
                if mgr.dsready {
                    Image(systemName: "checkmark.circle")
                } else if mgr.dsrunning {
                    HStack {
                        Text("\(Int(mgr.dsprogress * 100))%")
                        ProgressView()
                    }
                } else if mgr.dsattempted && mgr.dsfailed {
                    Image(systemName: "xmark.circle")
                }
            }) {
                Button("运行漏洞利用", action: {
                    offsets_init()
                    mgr.run()
                })
                .disabled(mgr.dsready || mgr.dsrunning || isdebugged())
            }

            if !mgr.hasOffsets {
                Button {
                    guard !dlingkcache else { return }
                    dlingkcache = true
                    DispatchQueue.global(qos: .userInitiated).async {
                        let fetched = fetchkcache()
                        if fetched {
                            let dlkc = dlkcache()
                            DispatchQueue.main.async {
                                mgr.hasOffsets = dlkc
                                dlingkcache = false
                            }
                            return
                        }
                        DispatchQueue.main.async {
                            mgr.hasOffsets = false
                            dlingkcache = false
                        }
                    }
                } label: {
                    if dlingkcache {
                        HStack {
                            Text("正在获取内核缓存...")
                            Spacer()
                            ProgressView()
                        }
                    } else {
                        Text("获取内核缓存")
                    }
                }
                .disabled(dlingkcache || !mgr.dsready)
            } else {
                if selectedmethod == .hybrid {
                    LabeledContent(content: {
                        if mgr.vfsready && mgr.sbxready {
                            Image(systemName: "checkmark.circle")
                        } else if mgr.vfsrunning || mgr.sbxrunning {
                            HStack {
                                Text("运行中...")
                                ProgressView()
                            }
                        } else if (mgr.vfsattempted && mgr.vfsfailed) || (mgr.sbxattempted && mgr.sbxfailed) {
                            Image(systemName: "xmark.circle")
                        }
                    }) {
                        Button("初始化系统", action: {
                            mgr.vfsinit()
                            mgr.sbxescape()
                        })
                        .disabled(!mgr.hasOffsets || !mgr.dsready || mgr.vfsrunning || mgr.sbxrunning || (mgr.vfsready && mgr.sbxready))
                    }
                }
                if selectedmethod == .vfs {
                    LabeledContent(content: {
                        if mgr.vfsready {
                            Image(systemName: "checkmark.circle")
                        } else if mgr.vfsrunning {
                            HStack {
                                Text("\(Int(mgr.dsprogress * 100))%")
                                ProgressView()
                            }
                        } else if mgr.vfsattempted && mgr.vfsfailed {
                            Image(systemName: "xmark.circle")
                        }
                    }) {
                        Button("初始化 VFS", action: {
                            mgr.vfsinit()
                        })
                        .disabled(!mgr.dsready || mgr.vfsready || mgr.vfsrunning || isdebugged())
                    }
                }
                if selectedmethod == .sbx {
                    LabeledContent(content: {
                        if mgr.sbxready {
                            Image(systemName: "checkmark.circle")
                        } else if mgr.sbxrunning {
                            HStack {
                                Text("运行中...")
                                ProgressView()
                            }
                        } else if mgr.sbxattempted && mgr.sbxfailed {
                            Image(systemName: "xmark.circle")
                        }
                    }) {
                        Button("逃逸沙盒", action: {
                            mgr.sbxescape()
                        })
                        .disabled(!mgr.dsready || mgr.sbxready || mgr.sbxrunning || isdebugged())
                    }
                }
            }
        } header: {
            HeaderLabel(text: "内核读写", icon: "externaldrive")
        } footer: {
            if isdebugged() {
                Text("附加调试器时不可用。")
            }
        }
    }

    private var RCSection: some View {
        Group {
            #if !DISABLE_REMOTECALL
            Section {
                LabeledContent(content: {
                    if mgr.rcready {
                        Image(systemName: "checkmark.circle")
                    } else if mgr.rcrunning {
                        HStack {
                            Text("运行中...")
                            ProgressView()
                        }
                    } else if mgr.rcfailed {
                        Image(systemName: "xmark.circle")
                    }
                }) {
                    Button("初始化远程调用", action: {
                        mgr.rcinit(process: "SpringBoard", migbypass: false) { success in
                            if success {
                                mgr.logmsg("远程调用初始化成功！")
                                let pid = mgr.rccall(name: "getpid")
                                mgr.logmsg("远程 getpid() 返回：\(pid)")
                                // 调通远程调用后直接显示全局悬浮时间
                                mgr.startClock()
                            } else {
                                mgr.logmsg("远程调用初始化失败")
                                mgr.rcfailed = true
                            }
                        }
                    })
                    .disabled(!mgr.dsready || isdebugged() || mgr.rcrunning || mgr.rcready)
                }

                if mgr.rcready {
                    Button("销毁远程调用", action: {
                        mgr.rcdestroy()
                    })
                }

                LabeledContent("全局悬浮时间") {
                    Text(mgr.clockrunning ? "已显示" : "未显示")
                        .foregroundColor(mgr.clockrunning ? .green : .secondary)
                }

                if !mgr.clockstatus.isEmpty {
                    Text(mgr.clockstatus)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
            } header: {
                HeaderLabel(text: "远程调用", icon: "syringe")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if let error = mgr.rcLastError ?? mgr.sbProc?.lastError {
                        Text("错误: \(error)")
                            .foregroundColor(.red)
                    }
                    if RemoteCall.isLiveContainerRuntime() && !RemoteCall.isLiveProcessRuntime() {
                        Text("远程调用需要支持 PAC 的 LiveContainer 启动上下文。当远程调用不可用时，主漏洞利用可能仍然有效。")
                    }
                    if isdebugged() {
                        Text("附加调试器时不可用。")
                    }
                    Text("远程调用相对不稳定，可能无法正常工作。")
                    if isIOS16() {
                        Text("iOS 16 提示：点击\"初始化远程调用\"后打开控制中心。这可以显著提高成功率和速度。")
                            .fontWeight(.semibold)
                            .foregroundColor(.orange)
                        Text("如果初始化在大约 2 分钟后失败，请执行 Respring，重新启动 Lara，然后重试。")
                            .fontWeight(.semibold)
                            .foregroundColor(.red)
                    }
                }
                .font(.footnote)
            }
            #endif
        }
    }

    private var ActionsSection: some View {
        Section {
            Button("Respring（重启 SpringBoard）", action: {
                mgr.respring()
            })
            Button("触发内核崩溃！", action: {
                mgr.panic()
            })
            if isdebugged() {
                Button("分离调试器", action: {
                    exit(0)
                })
            }
        }
    }

    private var DebugSection: some View {
        Group {
            if weonadebugbuild_pjbweouttahereexclamationmark {
                if mgr.dsready {
                    Section(header: HeaderLabel(text: "仅调试模式", icon: "ant")) {
                        LabeledContent("内核基址") {
                            Text(String(format: "0x%llx", mgr.kernbase))
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                        LabeledContent("内核滑动值") {
                            Text(String(format: "0x%llx", mgr.kernslide))
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var InlineLogsSection: some View {
        if selectedlogsdisplaymode == .content {
            Section {
                ScrollView {
                    if loggernobs {
                        let combined = logger.logs.joined(separator: "\n")
                        Text(combined)
                            .font(.system(size: 13, design: .monospaced))
                            .lineSpacing(1)
                            .textSelection(.enabled)
                            .onTapGesture {
                                UIPasteboard.general.string = combined
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            }
                    } else {
                        ForEach(Array(logger.logs.enumerated()), id: \.offset) { _, log in
                            Text(log)
                                .font(.system(size: 13, design: .monospaced))
                                .lineSpacing(1)
                                .textSelection(.enabled)
                                .onTapGesture {
                                    UIPasteboard.general.string = log
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                }
                        }
                    }
                }
                .frame(height: 250)

                Button("全部复制") {
                    UIPasteboard.general.string = logger.logs.joined(separator: "\n\n")
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                }

                Button("清除") {
                    logger.clear()
                }
                .foregroundColor(.red)
            } header: {
                HeaderLabel(text: "日志", icon: "terminal")
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(laramgr())
}
