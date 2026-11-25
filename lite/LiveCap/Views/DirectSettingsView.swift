import SwiftUI
import UIKit

/// 设置：只留四样——API 凭据填写、保存、测试连接、字幕样式入口。
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

    var body: some View {
        Form {
            Section {
                field("AppID", text: $appID, placeholder: "AppID")

                VStack(alignment: .leading, spacing: 6) {
                    Text("Access Token")
                        .font(DSFont.body)
                        .foregroundStyle(DSColor.label)
                    HStack(spacing: 8) {
                        if showToken {
                            TextField("Access Token", text: $token)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .font(.system(.body, design: .monospaced))
                        } else {
                            SecureField("Access Token", text: $token)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .font(.system(.body, design: .monospaced))
                        }
                        Button {
                            showToken.toggle()
                        } label: {
                            Image(systemName: showToken ? "eye.slash" : "eye")
                                .foregroundStyle(DSColor.secondaryLabel)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(showToken ? "隐藏" : "显示")
                    }
                }

                field("Resource ID", text: $resource, placeholder: "Resource ID")
            }

            Section {
                Button {
                    save()
                } label: {
                    Text("保存")
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
                        .font(DSFont.body)
                        .foregroundStyle(r.hasPrefix("连接正常") ? DSColor.label : DSColor.destructive)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section {
                Button {
                    showStyle = true
                } label: {
                    HStack {
                        Text("字幕样式")
                            .foregroundStyle(DSColor.label)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(DSColor.tertiaryLabel)
                    }
                }
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
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(DSFont.body)
                .foregroundStyle(DSColor.label)
            TextField(placeholder, text: text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(.body, design: .monospaced))
        }
    }

    private func save() {
        ZKDoubaoAST.saveAppID(appID, token: token, resource: resource)
        appID = ZKDoubaoAST.savedAppID()
        token = ZKDoubaoAST.savedToken()
        resource = ZKDoubaoAST.savedResource()
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
