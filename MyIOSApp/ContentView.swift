import SwiftUI

struct ContentView: View {
    @State private var count = 0

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground)
                .ignoresSafeArea()

            VStack(spacing: 24) {
                Text("Hello iPhone!")
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(.primary)

                VStack(spacing: 8) {
                    Text("Count")
                        .font(.headline)
                        .foregroundStyle(.secondary)

                    Text("\(count)")
                        .font(.system(size: 56, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                        .accessibilityLabel("Count \(count)")
                }

                Button {
                    count += 1
                } label: {
                    Label("Count Up", systemImage: "plus")
                        .font(.headline)
                        .frame(minWidth: 160)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityHint("Increases the count by one")
            }
            .padding()
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
