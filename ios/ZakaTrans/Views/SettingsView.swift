import SwiftUI

struct SettingsView: View {
    @ObservedObject private var cloud = Cloud.shared
    @State private var sourceLang = ZKStore.setting("asrlang") ?? "zh"
    @State private var destLang = ZKStore.setting("dstlang") ?? "en"
    @State private var hotwords = ZKStore.setting("hotwords") ?? ""
    @State private var saved = false

    private let languages: [(String, String)] = [
        ("zh", "中文"), ("en", "English"), ("ja", "日本語"), ("ko", "한국어"),
        ("es", "Español"), ("fr", "Français"), ("de", "Deutsch"), ("ru", "Русский"),
        ("pt", "Português"), ("it", "Italiano"), ("ar", "العربية"), ("th", "ไทย"),
        ("vi", "Tiếng Việt"), ("id", "Indonesia"),
    ]

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 16) {
                    langCard
                    hotwordCard
                    accountCard
                    aboutCard
                }
                .padding(16)
            }
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var langCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("语言")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.ink)

            row("源语言") {
                Picker("", selection: $sourceLang) {
                    ForEach(languages, id: \.0) { Text($0.1).tag($0.0) }
                }
                .pickerStyle(.menu)
                .onChange(of: sourceLang) { v in
                    ZKStore.setSetting("asrlang", v: v)
                    ZKSpeechStream.shared()!.reloadLocale()
                }
            }
            Divider().overlay(Theme.line)
            row("译文语言") {
                Picker("", selection: $destLang) {
                    ForEach(languages, id: \.0) { Text($0.1).tag($0.0) }
                }
                .pickerStyle(.menu)
                .onChange(of: destLang) { v in
                    ZKStore.setSetting("dstlang", v: v)
                    ZKSpeechStream.shared()!.reloadLocale()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func row<T: View>(_ title: String, @ViewBuilder trailing: () -> T) -> some View {
        HStack {
            Text(title).font(.system(size: 14)).foregroundStyle(Theme.ink)
            Spacer()
            trailing()
        }
    }

    private var hotwordCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("热词")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.ink)
            Text("一行一个，帮助识别专有名词、人名、产品名。")
                .font(.system(size: 12))
                .foregroundStyle(Theme.sub)
            TextEditor(text: $hotwords)
                .font(.system(size: 14))
                .frame(minHeight: 90)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color(white: 0.97))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            Button {
                ZKStore.setSetting("hotwords", v: hotwords)
                saved = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { saved = false }
            } label: {
                Text(saved ? "已保存" : "保存")
            }
            .buttonStyle(SecondaryButtonStyle())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var accountCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("账号")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.ink)
            HStack {
                Text("设备编号").font(.system(size: 13)).foregroundStyle(Theme.sub)
                Spacer()
                Text(String(cloud.accountID.prefix(8)))
                    .font(.system(size: 12).monospaced())
                    .foregroundStyle(Theme.ink)
            }
            HStack {
                Text("剩余额度").font(.system(size: 13)).foregroundStyle(Theme.sub)
                Spacer()
                Text(Purchases.format(cloud.balance) + " token")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Theme.ink)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var aboutCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("关于")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.ink)
            HStack {
                Text("版本").font(.system(size: 13)).foregroundStyle(Theme.sub)
                Spacer()
                Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-")
                    .font(.system(size: 12).monospaced())
                    .foregroundStyle(Theme.ink)
            }
            Text("字幕由同声传译模型实时生成，网络波动时可能延迟。机密内容请勿依赖自动译文作为唯一依据。")
                .font(.system(size: 11))
                .foregroundStyle(Theme.sub)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}
