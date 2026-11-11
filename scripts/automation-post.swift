// Development only: sends one named command to a SilkNest started with --automation (see scripts/perf.sh).
import Foundation
DistributedNotificationCenter.default().postNotificationName(Notification.Name("studio.webber.automation"),object:CommandLine.arguments[1],userInfo:nil,deliverImmediately:true)
