import SwiftUI
import UIKit

/// 设置：只保留这个工具版用得上的两件事——豆包 API 凭据、字幕样式。
///
/// 凭据是使用者自己申请的，存在本机钥匙串里，不上传任何地方，
/// 也不随安装包分发（所以打包发出去给谁，用的都是他自己那份额度）。
struct DirectSettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var appID = ZKDoubaoAST.savedAppID()
    @State private var token = ZKDoubaoAST.savedToken()
    @State private var resource = ZKDoubaoAST.savedResource()
    @State private var showToken = false
    @State private var showStyle = false
    @State private var testing = false
    @State private var testResult: String?
    @State private var savedToast: String?

    private var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(v) (\(b))"
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("把你的豆包 API 填进来")
                        .font(DSFont.headline)
                    Text("这个 App 不经过任何服务器，声音直接从这台手机发到豆包，原文和译文直接回来。填的是你自己账号的凭据，用多少算你自己账号的。")
                        .font(DSFont.footnote)
                        .foregroundStyle(DSColor.secondaryLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 2)
            }

            Section {
                field("AppID", text: $appID, placeholder: "例如 1234567890")
                HStack {
                    if showToken {
                        field("Access Token", text: $token, placeholder: "控制台里的 Access Token")
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Access Token")
                                .font(DSFont.footnote)
                                .foregroundStyle(DSColor.secondaryLabel)
                            SecureField("控制台里的 Access Token", text: $token)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .font(.system(.body, design: .monospaced))
                        }
                    }
                    Button {
                        showToken.toggle()
                    } label: {
                        Image(systemName: showToken ? "eye.slash" : "eye")
                            .foregroundStyle(DSColor.secondaryLabel)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(showToken ? "隐藏 Token" : "显示 Token")
                }
                field("Resource ID", text: $resource, placeholder: "volc.service_type.10053")
            } header: {
                Text("API 凭据")
            } footer: {
                Text("凭据只存在本机钥匙串，卸载 App 才会清掉。Resource ID 不填就用 volc.service_type.10053（同声传译大模型）。")
            }

            Section {
                Button {
                    save()
                } label: {
                    HStack {
                        Text("保存")
                        Spacer()
                        if let t = savedToast {
                            Text(t).font(DSFont.footnote).foregroundStyle(DSColor.secondaryLabel)
                        }
                    }
                }

                Button {
                    save()
                    test()
                } label: {
                    HStack {
                        Text(testing ? "正在连接…" : "测试连接")
                        Spacer()
                        if testing { ProgressView() }
                    }
                }
                .disabled(testing || appID.isEmpty || token.isEmpty)

                if let r = testResult {
                    Text(r)
                        .font(DSFont.footnote)
                        .foregroundStyle(r.hasPrefix("连接正常") ? DSColor.secondaryLabel : DSColor.destructive)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("连接")
            } footer: {
                Text("「测试连接」会真的建一次会话（不送声音，几秒就断），用来确认 AppID、Token、Resource ID 三项都通。")
            }

            Section("字幕") {
                Button {
                    showStyle = true
                } label: {
                    HStack {
                        Text("字幕样式")
                            .foregroundStyle(DSColor.label)
                        Spacer()
                        Text("字号 · 颜色 · 窗口")
                            .font(DSFont.footnote)
                            .foregroundStyle(DSColor.secondaryLabel)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(DSColor.secondaryLabel)
                    }
                }
            }

            Section("怎么申请凭据") {
                VStack(alignment: .leading, spacing: 8) {
                    step("1", "登录火山引擎控制台，开通「同声传译大模型」（AST v2）")
                    step("2", "在智能语音应用里创建应用，拿到 AppID 和 Access Token")
                    step("3", "确认这个应用已经开通 volc.service_type.10053 这个资源")
                    step("4", "把三项填到上面，点「测试连接」，通了就能直接用")
                }
                .padding(.vertical, 2)
            }

            Section("关于") {
                HStack {
                    Text("版本")
                    Spacer()
                    Text(version)
                        .foregroundStyle(DSColor.secondaryLabel)
                }
                HStack {
                    Text("运行方式")
                    Spacer()
                    Text("直连豆包")
                        .foregroundStyle(DSColor.secondaryLabel)
                }
                Text("这个版本只做实时字幕：录屏声音或麦克风声音进模型，画中画和对话记录出原文与译文。没有账号、没有积分、没有内购、没有中间服务器，凭据和字幕都只在这台设备上。")
                    .font(DSFont.footnote)
                    .foregroundStyle(DSColor.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") { dismiss() }
            }
        }
        .sheet(isPresented: $showStyle) {
            NavigationStack {
                SubtitleSettingsView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") { showStyle = false }
                        }
                    }
            }
        }
    }

    private func field(_ title: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(DSFont.footnote)
                .foregroundStyle(DSColor.secondaryLabel)
            TextField(placeholder, text: text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(.body, design: .monospaced))
        }
    }

    private func step(_ n: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(n)
                .font(DSFont.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(DSColor.secondaryLabel)
                .frame(width: 18, height: 18)
                .background(DSColor.fill, in: Circle())
            Text(text)
                .font(DSFont.footnote)
                .foregroundStyle(DSColor.label)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func save() {
        ZKDoubaoAST.saveAppID(appID, token: token, resource: resource)
        appID = ZKDoubaoAST.savedAppID()
        token = ZKDoubaoAST.savedToken()
        resource = ZKDoubaoAST.savedResource()
        savedToast = "已保存"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            if savedToast == "已保存" { savedToast = nil }
        }
    }

    private func test() {
        testing = true
        testResult = nil
        let probe = ZKDoubaoAST()
        probe.probe { result in
            testing = false
            testResult = result
        }
    }
}
