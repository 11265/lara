//
//  laramgr.swift
//  lara
//
//  Created by ruter on 23.03.26.
//

import Combine
import Foundation
import Darwin
import notify
import UIKit
import WebKit

private func loadMutablePropertyListDictionary(from url: URL) throws -> NSMutableDictionary {
    let data = try Data(contentsOf: url)
    var format = PropertyListSerialization.PropertyListFormat.binary
    let plist = try PropertyListSerialization.propertyList(
        from: data,
        options: [.mutableContainersAndLeaves],
        format: &format
    )
    guard let dict = plist as? NSMutableDictionary else {
        throw "Property list root is not a dictionary."
    }
    return dict
}

private func clearImmutableForOverwriteIfNeeded(path: String) -> String? {
    let majorVersion = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    guard majorVersion == 16 else { return nil }
    let fm = FileManager.default
    guard let attributes = try? fm.attributesOfItem(atPath: path) else { return nil }
    var updates: [FileAttributeKey: Any] = [:]
    if (attributes[.immutable] as? NSNumber)?.boolValue == true { updates[.immutable] = false }
    if (attributes[.appendOnly] as? NSNumber)?.boolValue == true { updates[.appendOnly] = false }
    guard !updates.isEmpty else { return nil }
    do {
        try fm.setAttributes(updates, ofItemAtPath: path)
        return nil
    } catch {
        return "clear immutable failed: \(error.localizedDescription)"
    }
}

final class laramgr: ObservableObject {
    @Published var log: String = ""
    @Published var hasOffsets: Bool = false
    @Published var dsrunning: Bool = false
    @Published var dsready: Bool = false
    @Published var dsattempted: Bool = false
    @Published var dsfailed: Bool = false
    @Published var dsprogress: Double = 0.0
    @Published var kernbase: UInt64 = 0
    @Published var kernslide: UInt64 = 0
    @Published var kaccessready: Bool = false
    @Published var kaccesserror: String?
    @Published var fileopinprogress: Bool = false
    @Published var testresult: String?
    #if !DISABLE_REMOTECALL
    @Published var rcrunning: Bool = false
    @Published var eligibilitystate: Bool?
    @Published var eu1progress: Double = 0.0
    @Published var eu1running: Bool = false
    @Published var eu2progress: Double = 0.0
    @Published var eu2running: Bool = false
    @Published var rcLastError: String?
    #endif
    @Published var vfsready: Bool = false
    @Published var vfsinitlog: String = ""
    @Published var vfsattempted: Bool = false
    @Published var vfsfailed: Bool = false
    @Published var vfsrunning: Bool = false
    @Published var vfsprogress: Double = 0.0
    @Published var sbxready: Bool = false
    @Published var sbxattempted: Bool = false
    @Published var sbxfailed: Bool = false
    @Published var sbxrunning: Bool = false
    @Published var rcready: Bool = false
    @Published var rcfailed: Bool = false
    @Published var showrespring: Bool = false
    @Published var showLogs: Bool = false
    @Published var clockrunning: Bool = false
    @Published var clockstatus: String = ""
    @Published var clockstarting: Bool = false      // 正在建浮层：防止并发远程调用
    @Published var fpvOn: Bool = false              // 「开启」开关的真实状态（唯一驱动源）

    var sbProc: RemoteCall?
    // 注意：这里以前有个 `var ytProc = RemoteCall(process: "youtube")` 的成员初始化。
    // 它会在 laramgr 单例构造时（也就是 app 一启动、漏洞原语尚未就绪时）立刻去
    // proc_find_by_name / 读内核内存，属于未初始化就读内核——极可能就是那次内核
    // panic（"Unexpected fault in kernel static region"）的元凶。而且它全程没被用到，
    // 已删除。

    static let shared = laramgr()
    static let fontpath = "/System/Library/Fonts/Core/SFUI.ttf"
    static let italicfontpath = "/System/Library/Fonts/Core/SFUIItalic.ttf"
    static let monofontpath = "/System/Library/Fonts/Core/SFUIMono.ttf"

    init() {}

    struct AppInfo {
        let executable: String
        let displayName: String
        let bundleName: String
        let dataFolder: String
        let bundleFolder: String
    }

    func run(completion: ((Bool) -> Void)? = nil) {
        guard !dsrunning else { return }
        dsrunning = true
        dsready = false
        dsfailed = false
        dsattempted = true
        dsprogress = 0.0
        log = ""
        ds_set_log_callback { messageCStr in
            guard let messageCStr else { return }
            let message = String(cString: messageCStr)
            DispatchQueue.main.async {
                laramgr.shared.logmsg("(ds) \(message)")
            }
        }
        ds_set_progress_callback { progress in
            DispatchQueue.main.async {
                laramgr.shared.dsprogress = progress
            }
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = ds_run()
            DispatchQueue.main.async {
                guard let self else { return }
                self.dsrunning = false
                let success = result == 0 && ds_is_ready()
                if success {
                    self.dsready = true
                    self.dsfailed = false
                    self.kernbase = ds_get_kernel_base()
                    self.kernslide = ds_get_kernel_slide()
                    self.logmsg("\n(ds) exploit success!")
                    self.logmsg(String(format: "(ds) kernel_base: 0x%llx", self.kernbase))
                    self.logmsg(String(format: "(ds) kernel_slide: 0x%llx\n", self.kernslide))
                    globallogger.log("(ds) exploit success!")
                    globallogger.log(String(format: "(ds) kernel_base: 0x%llx", self.kernbase))
                    /* 「初始化」把他俩合成一步：漏洞利用成功后接着做系统初始化
                       （VFS + 沙盒逃逸），用户不用再点第二次。 */
                    self.initSystemIfNeeded()
                    globallogger.log(String(format: "(ds) kernel_slide: 0x%llx", self.kernslide))
                    globallogger.divider()
                } else {
                    self.dsfailed = true
                    self.logmsg("\nexploit failed.\n")
                    globallogger.log("exploit failed.")
                    globallogger.divider()
                }
                self.dsprogress = 1.0
                completion?(success)
            }
        }
    }

    func logmsg(_ message: String) {
        DispatchQueue.main.async {
            self.log += message + "\n"
            globallogger.log(message)
        }
    }

    func kread64(address: UInt64) -> UInt64 {
        guard dsready else { return 0 }
        return ds_kread64(address)
    }

    func kwrite64(address: UInt64, value: UInt64) {
        guard dsready else { return }
        ds_kwrite64(address, value)
    }

    func kread32(address: UInt64) -> UInt32 {
        guard dsready else { return 0 }
        return ds_kread32(address)
    }

    func kwrite32(address: UInt64, value: UInt32) {
        guard dsready else { return }
        ds_kwrite32(address, value)
    }

    func panic() {
        guard dsready else { return }
        globallogger.log("triggering panic")
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            let kernbase = ds_get_kernel_base()
            globallogger.log("writing to read-only memory at kernel base")
            ds_kwrite64(kernbase, 0xDEADBEEF)
        }
    }

    func respring() {
        showrespring = true
    }

    func vfsinit(completion: ((Bool) -> Void)? = nil) {
        guard dsready, hasOffsets, !vfsrunning else { return }
        vfs_setlogcallback(laramgr.vfslogcallback)
        vfs_setprogresscallback { progress in
            DispatchQueue.main.async {
                laramgr.shared.vfsprogress = progress
            }
        }
        vfsattempted = true
        vfsfailed = false
        vfsrunning = true
        vfsprogress = 0.0
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let r = vfs_init()
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.vfsready = (r == 0 && vfs_isready())
                if self.vfsready {
                    self.vfsfailed = false
                    self.logmsg("\nvfs ready!\n")
                } else {
                    self.vfsfailed = true
                    self.logmsg("\nvfs init failed.\n")
                }
                self.vfsrunning = false
                self.vfsprogress = 1.0
                completion?(self.vfsready)
            }
        }
    }

    func sbxescape(completion: ((Bool) -> Void)? = nil) {
        guard dsready, hasOffsets, !sbxrunning else { return }
        sbxattempted = true
        sbxfailed = false
        sbxrunning = true
        sbx_setlogcallback(laramgr.sbxlogcallback)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let r = sbx_escape(ds_get_our_proc())
            DispatchQueue.main.async {
                guard let self else { return }
                self.sbxready = (r == 0)
                if self.sbxready {
                    self.sbxfailed = false
                    self.logmsg("\nsandbox escape ready!\n")
                } else {
                    self.sbxfailed = true
                    self.logmsg("\nsandbox escape failed.\n")
                }
                self.sbxrunning = false
                completion?(self.sbxready)
            }
        }
    }

    private static let sbxlogcallback: @convention(c) (UnsafePointer<CChar>?) -> Void = { msg in
        guard let msg = msg else { return }
        let s = String(cString: msg)
        DispatchQueue.main.async {
            laramgr.shared.logmsg("(sbx) " + s)
        }
    }

    private static let vfslogcallback: @convention(c) (UnsafePointer<CChar>?) -> Void = { msg in
        guard let msg = msg else { return }
        let s = String(cString: msg)
        DispatchQueue.main.async {
            laramgr.shared.vfsinitlog += "(vfs) " + s + "\n"
            laramgr.shared.logmsg("(vfs) " + s)
        }
    }

    func vfslistdir(path: String) -> [(name: String, isDir: Bool)]? {
        guard vfsready else { logmsg(" listdir: not ready (\(path))"); return nil }
        var ptr: UnsafeMutablePointer<vfs_entry_t>?
        var count: Int32 = 0
        let r = vfs_listdir(path, &ptr, &count)
        guard r == 0, let entries = ptr else { logmsg(" listdir failed (\(path)) r=\(r)"); return nil }
        defer { vfs_freelisting(entries) }
        var items: [(String, Bool)] = []
        for i in 0..<Int(count) {
            let e = entries[i]
            let name = withUnsafePointer(to: e.name) { $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) } }
            items.append((name, e.d_type == 2))
        }
        logmsg(" listdir \(path) -> \(items.count)")
        return items.sorted { $0.0.lowercased() < $1.0.lowercased() }
    }

    func vfsread(path: String, maxSize: Int = 512 * 1024) -> Data? {
        guard vfsready else { return nil }
        let fsz = vfs_filesize(path)
        if fsz <= 0 { return nil }
        let toRead = min(Int(fsz), maxSize)
        var buf = [UInt8](repeating: 0, count: toRead)
        let n = vfs_read(path, &buf, toRead, 0)
        if n <= 0 { return nil }
        return Data(buf.prefix(Int(n)))
    }

    func vfswrite(path: String, data: Data) -> Bool {
        guard vfsready else { return false }
        return data.withUnsafeBytes { ptr in
            let n = vfs_write(path, ptr.baseAddress, data.count, 0)
            return n > 0
        }
    }

    func vfssize(path: String) -> Int64 {
        guard vfsready else { return -1 }
        return vfs_filesize(path)
    }

    func vfsoverwritefromlocalpath(target: String, source: String) -> Bool {
        print("(vfs) target \(source) -> \(target)")
        guard vfsready else { print("(vfs) not ready"); return false }
        guard FileManager.default.fileExists(atPath: source) else {
            print("(vfs) source file not found: \(source)"); return false
        }
        let r = vfs_overwritefile(target, source)
        print("(vfs) vfs_overwritefile returned: \(r)")
        if r == 0 { print("(vfs) file overwritten") } else { print("(vfs) failed to overwrite file") }
        return r == 0
    }

    func vfsoverwritewithdata(target: String, data: Data) -> Bool {
        guard vfsready else { return false }
        let tmp = NSTemporaryDirectory() + "vfs_src_\(arc4random()).bin"
        do { try data.write(to: URL(fileURLWithPath: tmp)) } catch { return false }
        let ok = vfsoverwritefromlocalpath(target: target, source: tmp)
        try? FileManager.default.removeItem(atPath: tmp)
        return ok
    }

    private func sbxoverwrite(path: String, data: Data) -> (ok: Bool, message: String) {
        let immutableMessage = clearImmutableForOverwriteIfNeeded(path: path)
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        if fd == -1 {
            let prefix = immutableMessage.map { "\($0), " } ?? ""
            return (false, "\(prefix)sbx open failed: errno=\(errno) \(String(cString: strerror(errno)))")
        }
        defer { close(fd) }
        var total = 0
        let wroteAll = data.withUnsafeBytes { ptr -> Bool in
            guard let base = ptr.baseAddress else { return ptr.count == 0 }
            while total < ptr.count {
                let n = write(fd, base.advanced(by: total), ptr.count - total)
                if n <= 0 { return false }
                total += n
            }
            return true
        }
        if !wroteAll { return (false, "sbx write failed: errno=\(errno) \(String(cString: strerror(errno)))") }
        if ftruncate(fd, off_t(total)) != 0 {
            return (false, "sbx truncate failed: errno=\(errno) \(String(cString: strerror(errno)))")
        }
        return (true, "ok (\(total) bytes)")
    }

    @discardableResult
    func lara_overwritefile(target: String, source: String, fallback_vfs: Bool = true) -> (ok: Bool, message: String) {
        guard FileManager.default.fileExists(atPath: source) else {
            return (false, "source file not found: \(source)")
        }
        let result: (ok: Bool, message: String)
        if sbxready {
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: source))
                result = sbxoverwrite(path: target, data: data)
            } catch {
                result = (false, "sbx read source failed: \(error.localizedDescription)")
            }
        } else {
            result = (false, "sbx not ready")
        }
        if result.ok { return result }
        guard fallback_vfs else { return result }
        guard vfsready else { return (false, result.message + " | vfs not ready") }
        let ok = vfsoverwritefromlocalpath(target: target, source: source)
        return ok ? (true, "ok (vfs overwrite)") : (false, result.message + " | vfs overwrite failed")
    }

    @discardableResult
    func lara_overwritefile(target: String, data: Data, fallback_vfs: Bool = true) -> (ok: Bool, message: String) {
        let result = sbxready ? sbxoverwrite(path: target, data: data) : (false, "sbx not ready")
        if result.0 { return result }
        guard fallback_vfs else { return result }
        guard vfsready else { return (false, result.1 + ", vfs not ready") }
        let ok = vfsoverwritewithdata(target: target, data: data)
        return ok ? (true, "vfs overwrite ok") : (false, result.1 + ", vfs overwrite failed")
    }

    func vfszeropage(at path: String, dumb: Bool) -> Bool {
        if dumb {
            guard vfsready else { self.logmsg("(vfs) zerofile failed (vfs not ready)"); return false }
            let ok = path.withCString { vfs_zerofile($0) } == 0
            if !ok { self.logmsg("(vfs) zerofile failed"); return false }
            self.logmsg("(vfs) zeroed \(path)")
            return true
        } else {
            let result = path.withCString { cpath in vfs_zeropage(cpath, 0) }
            if result != 0 { self.logmsg("(vfs) zeropage failed"); return false }
            self.logmsg("(vfs) zeroed first page of \(path)")
            return true
        }
    }

    func sbxgettoken(pid: Int32) -> UInt64? {
        let addr = sbx_gettoken(pid)
        guard addr != 0 else { return nil }
        return addr
    }

    func sbxgettokenstring(pid: Int32) -> String? {
        guard let cstr = sbx_copytoken(pid) else { return nil }
        defer { sbx_freestr(cstr) }
        return String(cString: cstr)
    }

    func sbxissuetoken(extClass: String, path: String) -> String? {
        guard let cstr = sbx_issue_token(extClass, path) else { return nil }
        defer { sbx_freestr(cstr) }
        return String(cString: cstr)
    }

    func sbxelevate() {
        DispatchQueue.main.async { sbx_elevate(); }
    }

    func isapfs(_ path: String) -> Bool {
        var s = statfs()
        guard path.withCString({ statfs($0, &s) }) == 0 else { return false }
        let fstypename = s.f_fstypename
        return withUnsafePointer(to: fstypename) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: fstypename)) {
                String(cString: $0) == "apfs"
            }
        }
    }

    func PPHelper() -> Bool {
        do {
            let fm = FileManager.default
            let dataFolder = "/private/var/mobile/Containers/Data/Application"
            let bundleFolder = "/private/var/containers/Bundle/Application"
            var bundleIDs = ["com.apple.PosterBoard"]
            if UIDevice.current.userInterfaceIdiom == .phone {
                bundleIDs.append("com.apple.CarPlayWallpaper")
            }
            guard let appList = getAppList() else { return false}
            var hashes: [String:String] = [:]
            for bundleID in bundleIDs {
                if let appInfo = appList[bundleID] {
                    hashes[bundleID] = appInfo.dataFolder
                } else {
                    logmsg("Could not find app with bundle ID \(bundleID).")
                    return false
                }
            }
            var PPbundleID = "com.leemin.Pocket-Poster"
            for (bundleID, info) in appList {
                if info.executable == "Pocket Poster" { PPbundleID = bundleID; break }
                else if info.executable == "LiveContainer" { PPbundleID = bundleID }
            }
            if let PPHash = appList[PPbundleID]?.dataFolder {
                for bundleID in hashes.keys {
                    let fileName = "Nugget" + bundleID.replacingOccurrences(of: "com.apple.", with: "") + "Hash"
                    let content = hashes[bundleID]!
                    let filePath = dataFolder + "/" + PPHash + "/Documents/" + fileName
                    try content.write(to: URL(fileURLWithPath: filePath), atomically: true, encoding: .utf8)
                    logmsg("Wrote hash \(content) to \(filePath)")
                }
                return true
            } else {
                logmsg("Please install Pocket Poster before using Pocket Poster Helper. If you do have Pocket Poster installed, make sure you did not modify the bundle ID. If you installed Pocket Poster inside of LiveContainer, make sure you also did not modify the bundle ID of LiveContainer.")
                return false
            }
        } catch {
            logmsg("Error with Pocket Poster Helper: \(error.localizedDescription)")
            return false
        }
    }

    func getAppList() -> [String:AppInfo]? {
        let fm = FileManager.default
        let dataFolder = "/private/var/mobile/Containers/Data/Application"
        let bundleFolder = "/private/var/containers/Bundle/Application"
        var appList: [String:AppInfo] = [:]
        do {
            let appData = try fm.contentsOfDirectory(atPath: dataFolder)
            for app in appData {
                if let plist = NSDictionary(contentsOf: URL(fileURLWithPath: dataFolder + "/" + app + "/.com.apple.mobile_container_manager.metadata.plist")),
                   let bundleID = plist["MCMMetadataIdentifier"] as? String {
                    appList[bundleID] = AppInfo(executable: "", displayName: "", bundleName: "", dataFolder: app, bundleFolder: "")
                }
            }
            let appBundles = try fm.contentsOfDirectory(atPath: bundleFolder)
            for app in appBundles {
                let appPath = bundleFolder + "/" + app
                let contents = try fm.contentsOfDirectory(atPath: appPath)
                for item in contents {
                    if item.hasSuffix(".app") {
                        if let plist = NSDictionary(contentsOf: URL(fileURLWithPath: appPath + "/" + item + "/Info.plist")),
                           let bundleID = plist["CFBundleIdentifier"] as? String {
                            let executable = plist["CFBundleExecutable"] as? String ?? ""
                            let displayName = plist["CFBundleDisplayName"] as? String ?? ""
                            let bundleName = plist["CFBundleName"] as? String ?? ""
                            let dataFolderID = appList[bundleID]?.dataFolder ?? ""
                            let appInfo = AppInfo(executable: executable, displayName: displayName, bundleName: bundleName, dataFolder: dataFolderID, bundleFolder: app)
                            appList[bundleID] = appInfo
                        }
                        break
                    }
                }
            }
        } catch {
            logmsg("Error getting app list: \(error.localizedDescription)")
            return nil
        }
        return appList
    }

    func setplistvalue(path: String, key: (key: String, value: Any?), force: Bool = false) -> (ok: Bool, message: String) {
        do {
            let fm = FileManager.default
            var dict = NSMutableDictionary()
            if !fm.fileExists(atPath: path) {
                if !force { return (false, "file at \(path) does not exist or couldn't be found") }
            } else {
                dict = try loadMutablePropertyListDictionary(from: URL(fileURLWithPath: path))
            }
            if let value = key.value { dict[key.key] = value } else { dict.removeObject(forKey: key.key) }
            let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)
            let result = self.lara_overwritefile(target: path, data: data)
            if result.ok { return (true, "overwrote plist at path \(path)") }
            else { return(false, "overwrite failed: \(result.message)") }
        } catch {
            return (false, "an error occurred: \(error)")
        }
    }

    func getplistvalue(path: String, key: String) -> (ok: Bool, message: String, value: Any?) {
        do {
            let fm = FileManager.default
            if fm.fileExists(atPath: path) {
                let dict = try loadMutablePropertyListDictionary(from: URL(fileURLWithPath: path))
                if let value = dict[key] { return (true, "success", value) }
                else { return (false, "key \(key) not found", nil) }
            } else {
                return (false, "file at \(path) does not exist or couldn't be found", nil)
            }
        } catch {
            return (false, "an error occurred: \(error)", nil)
        }
    }

    @discardableResult
    func apfsown(path: String, uid: UInt32, gid: UInt32) -> Bool {
        if !isapfs(path) { print("\(path) is apfs!") }
        let result = path.withCString { cPath in apfs_own(cPath, uid_t(uid), gid_t(gid)) }
        if result != 0 { print("failed to chown \(path)"); return false }
        print("changed owner of \(path) to \(uid):\(gid)!")
        return true
    }

    // ── RemoteCall ──

    #if !DISABLE_REMOTECALL
    func rcinit(process: String, migbypass: Bool = false, completion: ((Bool) -> Void)? = nil) {
        guard dsready, !rcready else { completion?(false); return }
        rcrunning = true
        rcLastError = nil
        logmsg("initializing remote call on \(process)...")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.sbProc = RemoteCall(process: process, useMigFilterBypass: migbypass)
            DispatchQueue.main.async {
                guard let self = self else { return }
                let success = self.sbProc != nil
                if success {
                    self.logmsg("remote call initialized on \(process)")
                    self.rcLastError = nil
                    self.rcrunning = false
                    self.rcready = true
                    // 先把上次异常退出留下的崩溃面包屑发到电脑（有就发，没有就算）
                    self.uploadCrumbIfAny()
                    // 远程调用一就绪就自动显示全局悬浮·第一视角（除非上次是异常退出）
                    if self.consumeUncleanExitFlag() {
                        self.fpvOn = false
                    } else {
                        self.startClock()
                    }
                } else {
                    self.logmsg("remote call init failed on \(process)")
                    let error = RemoteCall.lastInitError()
                    self.rcLastError = error
                    if let error, !error.isEmpty {
                        self.logmsg("remote call init failed on \(process): \(error)")
                    } else {
                        self.logmsg("remote call init failed on \(process)")
                    }
                    self.rcrunning = false
                }
                completion?(success)
            }
        }
    }

    func rcinitDaemon(serviceName: String, framework: String? = nil, process: String, migbypass: Bool = false, completion: ((RemoteCall?) -> Void)? = nil) {
        guard dsready, let sbProc else { completion?(nil); return }
        rcrunning = true
        logmsg("initializing remote call on \(process)...")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            if process.withCString({ proc_find_by_name($0) == 0 }) {
                wake_up_daemon(sbProc, serviceName, framework)
                sleep(1)
            }
            let proc = RemoteCall(process: process, useMigFilterBypass: migbypass)
            completion?(proc)
            DispatchQueue.main.async {
                guard let self = self else { return }
                let success = proc != nil
                if success {
                    self.logmsg("remote call initialized on \(process)")
                    self.rcrunning = false
                } else {
                    let error = RemoteCall.lastInitError()
                    if let error, !error.isEmpty {
                        self.logmsg("remote call init failed on \(process): \(error)")
                    } else {
                        self.logmsg("remote call init failed on \(process)")
                    }
                    self.rcrunning = false
                }
            }
        }
    }

    func rcdestroy(completion: (() -> Void)? = nil) {
        guard rcready else { return }
        logmsg("destroying remote call session...")
        rcready = false
        // The floating clock keeps calling into this session, so shut it down first.
        let clockWasRunning = clockrunning
        clockrunning = false
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            if clockWasRunning, let sbProc = self?.sbProc {
                clock_overlay_stop(sbProc)
            }
            self?.sbProc?.destroy()
            // remote_objc's global helpers still point at the session we just
            // destroyed, so drop that binding as well.
            clock_overlay_unbind()
            DispatchQueue.main.async {
                self?.logmsg("remote call session destroyed")
                completion?()
            }
        }
    }

    func stashKRWToLaunchd(completion: ((Bool) -> Void)? = nil) {
        guard dsready, !rcrunning else { completion?(false); return }
        rcrunning = true
        rcLastError = nil
        logmsg("(persist) manually transferring KRW primitives to launchd...")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let success = transfer_krw_to_launchd()
            DispatchQueue.main.async {
                guard let self else { return }
                self.rcrunning = false
                if success {
                    self.rcLastError = nil
                    self.logmsg("(persist) manual KRW transfer to launchd succeeded")
                } else {
                    let error = RemoteCall.lastInitError()
                    self.rcLastError = error
                    if let error, !error.isEmpty {
                        self.logmsg("(persist) manual KRW transfer to launchd failed: \(error)")
                    } else {
                        self.logmsg("(persist) manual KRW transfer to launchd failed")
                    }
                }
                completion?(success)
            }
        }
    }

    func rccall(name: String, args: [UInt64] = [], timeout: Int32 = 100) -> UInt64 {
        guard rcready else { return 0 }
        let RTLD_DEFAULT = UnsafeMutableRawPointer(bitPattern: -2)
        let ptr = dlsym(RTLD_DEFAULT, name)
        var argsCopy = args
        return name.withCString { (cName: UnsafePointer<CChar>) -> UInt64 in
            UInt64(argsCopy.withUnsafeMutableBufferPointer { buffer in
                sbProc?.doStable(
                    withTimeout: timeout,
                    functionName: UnsafeMutablePointer(mutating: cName),
                    functionPointer: ptr,
                    args: buffer.baseAddress,
                    argCount: UInt(args.count)
                ) ?? 0
            })
        }
    }
    #endif

    // ── Floating overlay（全局悬浮·第一视角） ──

    /// 第一视角页面的局域网地址（电脑上跑 rr/fpv 的 server.py）。
    static let fpvDefaultURL = "http://192.168.137.1:18099/"

    private var orientationObserver: NSObjectProtocol?

    /// 把「用户手选的方向 + 是否全屏」推给浮层。浮层按本机真实分辨率自己重排 frame：
    /// 横屏 = 长短边对调铺开，全屏 = 铺满整屏；不会重建浮层、不会重新加载页面。
    /// 方向刻意**不做自动判断**：真机上 lara 侧与页面侧的信号都不可靠，直接听用户设置。
    func pushLayout() {
        let orient = UserDefaults.standard.string(forKey: "fpvOrient") ?? "landscape"
        lastLandscape = (orient != "portrait")            // 默认横屏
        let full = UserDefaults.standard.bool(forKey: "fpvFullscreen")
        clock_overlay_set_layout(lastLandscape ? 1 : 0, full ? 1 : 0)
    }

    private var lastLandscape = false

    /// 悬浮层现在用**原生 UIView** 绘制（参考 peace_esp）：方框是 layer 边框、文字是 UILabel。
    /// 数据仍走局域网：lara 直接轮询电脑上 rr/fpv 服务的 /api/state，压成一行交给 C 层。
    /// fpvURL 就是那个数据服务地址（例如 http://192.168.137.1:18099/）。
    func fpvDataBase() -> String {
        var base = (UserDefaults.standard.string(forKey: "fpvURL") ?? Self.fpvDefaultURL)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { base = Self.fpvDefaultURL }
        if !base.hasPrefix("http") { base = "http://" + base }
        var cut = base
        if let q = cut.firstIndex(of: "?") { cut = String(cut[cut.startIndex..<q]) }
        while cut.hasSuffix("/") { cut.removeLast() }
        return cut
    }

    /// 设置变更时同步给浮层：URL（诊断显示）+ 几何 + 方向 + 画面参数。
    func refreshOverlayUrl() {
        pushOverlayConfig()
    }

    func pushOverlayConfig() {
        let d = UserDefaults.standard
        fpvDataBase().withCString { clock_overlay_set_url($0) }
        let ratio = d.object(forKey: "fpvWidth") as? Double ?? 0.92
        let top = d.object(forKey: "fpvTop") as? Double ?? 56.0
        let hRatio = d.object(forKey: "fpvHeight") as? Double ?? 0.0
        clock_overlay_set_geometry(ratio, top)
        clock_overlay_set_height_ratio(hRatio)
        let fov = d.object(forKey: "fpvFov") as? Double ?? 90
        let eye = d.object(forKey: "fpvEye") as? Double ?? 1.6
        let dist = d.object(forKey: "fpvDist") != nil ? d.bool(forKey: "fpvDist") : true
        let cross = d.object(forKey: "fpvCross") != nil ? d.bool(forKey: "fpvCross") : true
        // 方框数量可选：默认 8（比 24 少一半以上远程调用与目标侧对象，先确认能不能稳）
        let slots = d.object(forKey: "fpvSlots") as? Int ?? 4
        clock_overlay_set_view(Int32(slots), fov, eye, 0, dist ? 1 : 0, cross ? 1 : 0)
        pushLayout()
    }

    // ── 崩溃面包屑：发现上次异常退出留下的文件就发给电脑上的服务 ──
    private var crumbUploaded = false
    func uploadCrumbIfAny() {
        guard !crumbUploaded else { return }
        crumbUploaded = true
        guard let url = URL(string: fpvDataBase() + "/api/crumb") else { return }
        let home = NSHomeDirectory()
        let path = home + "/Documents/fpv-crumb.log"
        guard let text = try? String(contentsOfFile: path, encoding: .utf8), !text.isEmpty else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = text.data(using: .utf8)
        req.timeoutInterval = 6
        URLSession.shared.dataTask(with: req) { [weak self] _, _, err in
            if let err { self?.logmsg("(fpv) 面包屑上传失败：\(err.localizedDescription)") }
            else { self?.logmsg("(fpv) 已把上次崩溃面包屑上传到电脑（server.py 旁的 crumbs.log）") }
        }.resume()
    }

    // ── 局域网数据：每 100ms 拉一次，压成 "self;x,y,z,kind;..." 交给浮层 ──
    private var snapTimer: Timer?
    private var snapBusy = false

    func startSnapshotPolling() {
        stopSnapshotPolling()
        snapTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.fetchSnapshot()
        }
        if let t = snapTimer { RunLoop.main.add(t, forMode: .common) }
    }

    func stopSnapshotPolling() {
        snapTimer?.invalidate()
        snapTimer = nil
        snapBusy = false
    }

    private func fetchSnapshot() {
        guard clockrunning, !snapBusy else { return }
        guard let url = URL(string: fpvDataBase() + "/api/state") else { return }
        snapBusy = true
        var req = URLRequest(url: url)
        req.timeoutInterval = 2
        req.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self else { return }
            var line = ""
            if let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let selfPos = obj["self"] as? [Double], selfPos.count >= 3 {
                let fresh = (obj["self_aim_yaw"] as? Double).map { _ in
                    (obj["self_aim_age_ms"] as? Double).map { $0 <= 250 } ?? true
                } ?? false
                let yaw = (fresh ? obj["self_aim_yaw"] as? Double : nil)
                    ?? (obj["self_yaw"] as? Double) ?? 0
                let pitch = (obj["self_pitch"] as? Double) ?? 0
                line = String(format: "%.1f,%.1f,%.1f,%.2f,%.2f", selfPos[0], selfPos[1], selfPos[2], yaw, pitch)
                if let ents = obj["entities"] as? [[String: Any]] {
                    var n = 0
                    for e in ents {
                        guard let w = e["world"] as? [Double], w.count >= 3 else { continue }
                        let kind: Int
                        if (e["kind"] as? String) == "mate" { kind = 1 }
                        else if (e["is_bot"] as? Bool) == true || (e["kind"] as? String) == "ai" { kind = 2 }
                        else { kind = 0 }
                        line += String(format: ";%.1f,%.1f,%.1f,%d", w[0], w[1], w[2], kind)
                        n += 1
                        if n >= 48 { break }
                    }
                }
            }
            self.snapBusy = false
            if line.isEmpty { clock_overlay_set_snapshot(nil) }
            else { line.withCString { clock_overlay_set_snapshot($0) } }
        }.resume()
    }

    /// 悬浮层开着的时候，把这个标记写进偏好；正常关闭时清掉。
    /// 启动时如果发现它还在，说明上次是**异常退出**（崩溃/被系统杀/桌面重启），
    /// 于是不再自动开启，避免一开就重启、无限循环。
    private let fpvRunningKey = "fpvWasRunning"

    func noteOverlayStarted() {
        UserDefaults.standard.set(true, forKey: fpvRunningKey)
    }
    func noteOverlayStopped() {
        UserDefaults.standard.set(false, forKey: fpvRunningKey)
    }
    /// 上次是否异常退出（返回 true 时调用方应跳过自动开启）
    func consumeUncleanExitFlag() -> Bool {
        let unclean = UserDefaults.standard.bool(forKey: fpvRunningKey)
        if unclean {
            UserDefaults.standard.set(false, forKey: fpvRunningKey)
            logmsg("(fpv) 检测到上次异常退出（可能是浮层导致的桌面重启），本次不自动开启；"
                   + "要试请在首页手动打开「开启」")
        }
        return unclean
    }

    func startClock() {
        guard dsready, let sbProc, !clockrunning, !clockstarting else { return }
        // 上次把远程会话弄坏后就上锁：不再自动重试，避免反复冲击参数缓冲区把 SpringBoard 打崩
        if clock_overlay_failed() {
            clockstatus = String(cString: clock_overlay_status())
            logmsg("(fpv) 已上锁，不再自动重试：请在第一视角页按「重新自检并显示」")
            return
        }
        // 悬浮层由 lara 进程驱动，lara 被挂起就会停：自动打开后台保活
        if !kaenabled {
            toggleka()
            UserDefaults.standard.set(true, forKey: "keepAlive")
            logmsg("(fpv) 已自动开启后台保活")
        }
        pushOverlayConfig()
        logmsg("(fpv) 启动原生绘制浮层：数据源 \(fpvDataBase())/api/state（\(lastLandscape ? "横屏" : "竖屏")\(UserDefaults.standard.bool(forKey: "fpvFullscreen") ? " 全屏" : "")）")
        clockstarting = true
        noteOverlayStarted()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let ok = clock_overlay_start(sbProc)
            let status = String(cString: clock_overlay_status())
            DispatchQueue.main.async {
                self?.clockstarting = false
                self?.clockrunning = ok
                self?.clockstatus = status
                self?.logmsg(ok ? "(fpv) \(status)" : "(fpv) 失败：\(status)")
                if ok { self?.startSnapshotPolling() } else { self?.fpvOn = false; self?.noteOverlayStopped() }
            }
        }
    }

    func stopClock() {
        guard clockrunning else { return }
        noteOverlayStopped()
        stopSnapshotPolling()
        guard let sbProc else {
            clockrunning = false
            return
        }
        logmsg("(fpv) 隐藏悬浮第一视角...")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            clock_overlay_stop(sbProc)
            let status = String(cString: clock_overlay_status())
            DispatchQueue.main.async {
                self?.clockrunning = false
                self?.clockstatus = status
                self?.logmsg("(fpv) \(status)")
            }
        }
    }

    // ── 一步到位：初始化 / 开启 ────────────────────────────────────────────

    private var systemInitStarted = false

    /// 「初始化」的第二步：漏洞利用成功后自动做系统初始化（VFS + 沙盒逃逸）。
    func initSystemIfNeeded() {
        guard dsready, !systemInitStarted else { return }
        systemInitStarted = true
        logmsg("(init) 漏洞利用完成，继续系统初始化…")
        vfsinit { [weak self] _ in
            self?.sbxescape { _ in
                self?.logmsg("(init) 系统初始化结束")
                self?.systemInitStarted = false
            }
        }
    }

    /// 「开启」：初始化远程调用 + 启动第一视角浮层，一步到位。
    /// 用一个独立状态 fpvOn 驱动开关：以前开关绑的是 clockrunning||rcrunning||clockstarting，
    /// 中途失败后这些中间态会复原，开关看起来却还是"开"，关掉又立刻被算回 true → 死循环。
    func enableAll() {
        guard !fpvOn else { return }
        // 上次失败后已上锁：不再反复重试（否则你每拨一次开关都会重新冲击一次远程会话）
        if clock_overlay_failed() {
            fpvOn = false
            clockstatus = String(cString: clock_overlay_status())
            logmsg("(开启) 已上锁，不重试：请在第一视角页按「重新自检并显示」")
            return
        }
        fpvOn = true
        if clockrunning { return }
        if rcready {
            startClock()
            return
        }
        guard !rcrunning, !clockstarting else { return }
        guard dsready else {
            clockstatus = "请先点「初始化」"
            fpvOn = false
            return
        }
        logmsg("(开启) 初始化远程调用…")
        rcinit(process: "SpringBoard", migbypass: false) { [weak self] success in
            guard let self else { return }
            if success {
                self.logmsg("远程调用初始化成功！")
                let pid = self.rccall(name: "getpid")
                self.logmsg("远程 getpid() 返回：\(pid)")
                self.startClock()
            } else {
                self.logmsg("远程调用初始化失败")
                self.rcfailed = true
                self.fpvOn = false
            }
        }
    }

    /// 「关闭」：停浮层。**不拆远程会话。**
    /// 拆会话（rcdestroy → mach_port_destruct）时，SpringBoard 里那个挂着的木马
    /// 线程一旦在 0x401 收到异常却没人应答，就会 SIGBUS，整个 SpringBoard 重开——
    /// 这正是「开一次关一次桌面就重开」的来源。会话随 lara 进程存活即可，代价是
    /// 强制退出 lara 时 SpringBoard 会注销一次（设置页已就此提醒）。
    func disableAll() {
        fpvOn = false
        stopClock()
    }

    /// 强制重建悬浮窗并逐步骤写日志（第一视角页的「重新自检并显示」按钮）。
    /// 这是唯一会解开「失败闩锁」的入口：会话被弄坏后必须由用户显式重试。
    func diagnoseClock() {
        guard dsready, let sbProc else {
            clockstatus = "远程调用未就绪"
            return
        }
        guard !clockstarting else { return }
        clockstatus = "自检运行中…"
        clockstarting = true
        logmsg("(fpv) 自检开始…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let ok = clock_overlay_selftest(sbProc)
            let status = String(cString: clock_overlay_status())
            DispatchQueue.main.async {
                self?.clockstarting = false
                self?.clockrunning = ok && clock_overlay_is_running()
                self?.clockstatus = status
                self?.logmsg("(fpv) 自检\(ok ? "成功" : "失败")：\(status)")
            }
        }
    }
}
