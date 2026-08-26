import Darwin
import Foundation
import OpenRecord

let exitCode = await OpenRecordAutomationCLI.run(
    arguments: Array(CommandLine.arguments.dropFirst())
)
exit(exitCode)
