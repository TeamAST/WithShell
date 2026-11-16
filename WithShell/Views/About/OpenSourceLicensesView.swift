import SwiftUI

/// 앱에 포함된 오픈소스 목록 (scripts/collect-licenses.py 가 만든 OpenSourceLicenses.json)
struct OpenSourceLicense: Decodable, Identifiable, Hashable {
    let name: String
    let version: String
    let license: String
    let url: String
    let text: String

    var id: String { name }

    static func loadBundled() -> [OpenSourceLicense] {
        guard let url = Bundle.main.url(forResource: "OpenSourceLicenses", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([OpenSourceLicense].self, from: data)
        else { return [] }
        return entries
    }
}

struct OpenSourceLicensesView: View {
    static let windowID = "open-source-licenses"

    @State private var licenses = OpenSourceLicense.loadBundled()
    @State private var selection: OpenSourceLicense.ID?

    var body: some View {
        NavigationSplitView {
            List(licenses, selection: $selection) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                    Text([entry.license, entry.version].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag(entry.id)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            if let entry = licenses.first(where: { $0.id == selection }) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(entry.name).font(.title2.bold())
                        HStack(spacing: 12) {
                            Text(entry.license)
                            if !entry.version.isEmpty { Text("버전 \(entry.version)") }
                            if let link = URL(string: entry.url) {
                                Link(entry.url, destination: link)
                            }
                        }
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        Divider()
                        Text(entry.text)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding()
                }
            } else {
                ContentUnavailableView {
                    Label("오픈소스 라이선스", systemImage: "doc.text")
                } description: {
                    Text("WithShell은 MIT 라이선스로 배포되며, 아래 오픈소스 소프트웨어를 사용합니다.\n왼쪽에서 항목을 선택하면 라이선스 전문을 볼 수 있습니다.")
                }
            }
        }
        .navigationTitle("오픈소스 라이선스")
        .onAppear { selection = selection ?? licenses.first?.id }
    }
}
