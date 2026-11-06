import Foundation

@main struct IntentCLI {
    static func result(_ data: Data, planner: IntentPlannerService) throws -> String {
        guard let input = try JSONSerialization.jsonObject(with:data) as? [String:Any] else {
            throw IntentPlanError("Input must be a JSON object.")
        }
        let apps = input["apps"] as? [[String:String]] ?? []
        if CommandLine.arguments.contains("--validate") {
            return IntentPlan.json(try IntentPlan.validate(input["plan"] as? [String:Any] ?? [:],
                appIDs:Set(apps.compactMap{$0["id"]})))
        }
        return planner.plan(text:input["text"] as? String ?? "",context:input["context"] as? [String:Any] ?? [:],apps:apps)
    }
    static func main() throws {
        let planner = IntentPlannerService()
        if CommandLine.arguments.contains("--stream") {
            while let line = readLine() {
                do { print(try result(Data(line.utf8),planner:planner)) }
                catch { print(IntentPlan.json(["error":error.localizedDescription])) }
                fflush(stdout)
            }
        } else {
            print(try result(FileHandle.standardInput.readDataToEndOfFile(),planner:planner))
        }
    }
}
