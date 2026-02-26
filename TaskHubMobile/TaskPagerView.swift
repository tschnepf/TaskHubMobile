import SwiftUI
import SwiftData

struct TaskPagerView: View {
    @State private var selection: TaskListScope = .all
    
    var body: some View {
        VStack {
            Picker("Task List Scope", selection: $selection) {
                Text("All").tag(TaskListScope.all)
                Text("Work").tag(TaskListScope.work)
                Text("Personal").tag(TaskListScope.personal)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            
            TabView(selection: $selection) {
                TaskListView(scope: .all)
                    .tag(TaskListScope.all)
                TaskListView(scope: .work)
                    .tag(TaskListScope.work)
                TaskListView(scope: .personal)
                    .tag(TaskListScope.personal)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
    }
}

#Preview {
    TaskPagerView()
        .modelContainer(for: TaskItem.self, inMemory: true)
}

