import Foundation
import TestHelpers
import Testing

@Suite(.ownThreads)
struct OwnThreadsTests {
    @Test
    func testOfASuiteWithTheTraitRunsOnAThreadOfItsOwn() {
        guard #available(macOS 15.0, *) else {
            return
        }
        #expect(Thread.current.name == OwnThreads.threadName)
    }

    @Test(arguments: [1, 2])
    func eachCaseOfATestWithArgumentsRunsOnAThreadOfItsOwn(number _: Int) async {
        guard #available(macOS 15.0, *) else {
            return
        }
        await Task.yield()
        #expect(Thread.current.name == OwnThreads.threadName)
    }
}
