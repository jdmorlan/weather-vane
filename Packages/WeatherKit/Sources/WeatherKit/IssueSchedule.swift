//
//  IssueSchedule.swift  (WeatherKit)
//
//  WHEN THE OFFICES PUBLISH, so a product can say when its next copy is due.
//
//  The outlooks carry their own issue time but nothing about the next one, and
//  the offices do not reissue on a whim — they publish on fixed schedules. So
//  "next expected" is read off the schedule rather than guessed from the gap
//  between the last two copies, which would be wrong every time a forecaster
//  sent a special update.
//
//  THE SCHEDULES, AS THE OFFICES STATE THEM (checked 30 September 2026):
//
//    SPC  (spc.noaa.gov/misc/about.html)
//      Day 1   0100Z 0600Z 1300Z 1630Z 2000Z
//      Day 2   1:00 AM Central (CST and CDT alike)   and 1730Z
//      Day 3   2:30 AM Central (CST and CDT alike)   and 1930Z
//
//    WPC  (wpc.ncep.noaa.gov/html/fam2.shtml)
//      ERO Day 1         0100Z 0830Z 1600Z
//      ERO Days 2–3      0830Z 2030Z
//      QPF Days 1–3      1000Z 2200Z   (finals; preliminaries at 0530Z/1730Z)
//      QPF Days 4–7      0400Z 1600Z   — so a days-1-to-5 total moves at both
//
//  SPC's early day-2 and day-3 times are fixed in CENTRAL time, not UTC, which
//  is why a slot carries its own zone: 1 AM Central is 0600Z in summer and
//  0700Z in winter.
//
//  These are when the product is DUE. A special update can come sooner and a
//  busy shift can run late, which is why the UI says "expected", and says a
//  newer copy "was due" rather than pretending when a slot passes empty.
//

import Foundation

public struct IssueSchedule: Equatable, Sendable {
    public struct Slot: Equatable, Sendable {
        public var hour: Int
        public var minute: Int
        public var zone: TimeZone

        public static func utc(_ hour: Int, _ minute: Int = 0) -> Slot {
            Slot(hour: hour, minute: minute, zone: TimeZone(identifier: "UTC")!)
        }
        public static func central(_ hour: Int, _ minute: Int = 0) -> Slot {
            Slot(hour: hour, minute: minute, zone: TimeZone(identifier: "America/Chicago")!)
        }
    }

    public var slots: [Slot]

    public init(_ slots: [Slot]) { self.slots = slots }

    /// How early a copy can come out and still BE that slot's copy. WPC's
    /// 0830Z outlook was stamped 0756Z on 30 September; without this, the
    /// app would have announced the 0830Z copy as still to come for half an
    /// hour after it arrived. The closest two slots anywhere here are 3½ hours
    /// apart, so this can't swallow a real one.
    public static let earlyGrace: TimeInterval = 75 * 60

    /// The next copy due after one issued at `issued`.
    public func next(afterIssue issued: Date) -> Date? {
        next(after: issued.addingTimeInterval(Self.earlyGrace))
    }

    /// The first scheduled issuance strictly after `date`.
    public func next(after date: Date) -> Date? {
        slots.compactMap { slot in
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = slot.zone
            return calendar.nextDate(after: date,
                                     matching: DateComponents(hour: slot.hour, minute: slot.minute),
                                     matchingPolicy: .nextTime)
        }.min()
    }
}

extension IssueSchedule {
    /// SPC's convective outlook — the categorical map and the tornado, hail
    /// and wind probabilities are all parts of the same issuance.
    public static func spc(day: Int) -> IssueSchedule {
        switch day {
        case 1:  return IssueSchedule([.utc(1), .utc(6), .utc(13), .utc(16, 30), .utc(20)])
        case 2:  return IssueSchedule([.central(1), .utc(17, 30)])
        default: return IssueSchedule([.central(2, 30), .utc(19, 30)])
        }
    }

    /// WPC's Excessive Rainfall Outlook.
    public static func wpcExcessiveRain(day: Int) -> IssueSchedule {
        day == 1 ? IssueSchedule([.utc(1), .utc(8, 30), .utc(16)])
                 : IssueSchedule([.utc(8, 30), .utc(20, 30)])
    }

    /// WPC's rain totals through `days`. Past day 3 the total includes the
    /// days-4-to-7 forecast, so it moves on that schedule too.
    public static func wpcRainTotals(throughDay days: Int) -> IssueSchedule {
        days <= 3 ? IssueSchedule([.utc(10), .utc(22)])
                  : IssueSchedule([.utc(4), .utc(10), .utc(16), .utc(22)])
    }
}

extension OutlookProduct {
    public func schedule(period: Int) -> IssueSchedule {
        switch self {
        case .severeStorms:  return .spc(day: period)
        case .excessiveRain: return .wpcExcessiveRain(day: period)
        case .rainTotals:    return .wpcRainTotals(throughDay: period)
        }
    }
}

extension Outlook {
    /// Who drew it, when, and when the next copy is due.
    public var stamp: SourceStamp {
        let schedule = product.schedule(period: period)
        return SourceStamp(source: product.issuer,
                           made: issued.map { .issued($0) } ?? .unpublished,
                           next: issued.flatMap(schedule.next(afterIssue:)) ?? schedule.next(after: Date()))
    }
}

extension SevereProbability {
    public var stamp: SourceStamp {
        SourceStamp(source: "SPC",
                    made: issued.map { .issued($0) } ?? .unpublished,
                    next: issued.flatMap(IssueSchedule.spc(day: day).next(afterIssue:))
                        ?? IssueSchedule.spc(day: day).next(after: Date()))
    }
}
