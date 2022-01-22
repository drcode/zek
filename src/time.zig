const std = @import("std");
//DateTime code adapted from https://gist.github.com/WoodyAtHome/3ef50b17f0fa2860ac52b97af12f8d15

const TimeOffset = struct {
    from: i64,
    offset: i16,
};

const timeOffsets_Berlin = [_]TimeOffset{
    TimeOffset{ .from = 2140045200, .offset = 3600 }, // Sun Oct 25 01:00:00 2037
    TimeOffset{ .from = 2121901200, .offset = 7200 }, // Sun Mar 29 01:00:00 2037
    TimeOffset{ .from = 2108595600, .offset = 3600 }, // Sun Oct 26 01:00:00 2036
    TimeOffset{ .from = 2090451600, .offset = 7200 }, // Sun Mar 30 01:00:00 2036
    TimeOffset{ .from = 2077146000, .offset = 3600 }, // Sun Oct 28 01:00:00 2035
    TimeOffset{ .from = 2058397200, .offset = 7200 }, // Sun Mar 25 01:00:00 2035
    TimeOffset{ .from = 2045696400, .offset = 3600 }, // Sun Oct 29 01:00:00 2034
    TimeOffset{ .from = 2026947600, .offset = 7200 }, // Sun Mar 26 01:00:00 2034
    TimeOffset{ .from = 2014246800, .offset = 3600 }, // Sun Oct 30 01:00:00 2033
    TimeOffset{ .from = 1995498000, .offset = 7200 }, // Sun Mar 27 01:00:00 2033
    TimeOffset{ .from = 1982797200, .offset = 3600 }, // Sun Oct 31 01:00:00 2032
    TimeOffset{ .from = 1964048400, .offset = 7200 }, // Sun Mar 28 01:00:00 2032
    TimeOffset{ .from = 1950742800, .offset = 3600 }, // Sun Oct 26 01:00:00 2031
    TimeOffset{ .from = 1932598800, .offset = 7200 }, // Sun Mar 30 01:00:00 2031
    TimeOffset{ .from = 1919293200, .offset = 3600 }, // Sun Oct 27 01:00:00 2030
    TimeOffset{ .from = 1901149200, .offset = 7200 }, // Sun Mar 31 01:00:00 2030
    TimeOffset{ .from = 1887843600, .offset = 3600 }, // Sun Oct 28 01:00:00 2029
    TimeOffset{ .from = 1869094800, .offset = 7200 }, // Sun Mar 25 01:00:00 2029
    TimeOffset{ .from = 1856394000, .offset = 3600 }, // Sun Oct 29 01:00:00 2028
    TimeOffset{ .from = 1837645200, .offset = 7200 }, // Sun Mar 26 01:00:00 2028
    TimeOffset{ .from = 1824944400, .offset = 3600 }, // Sun Oct 31 01:00:00 2027
    TimeOffset{ .from = 1806195600, .offset = 7200 }, // Sun Mar 28 01:00:00 2027
    TimeOffset{ .from = 1792890000, .offset = 3600 }, // Sun Oct 25 01:00:00 2026
    TimeOffset{ .from = 1774746000, .offset = 7200 }, // Sun Mar 29 01:00:00 2026
    TimeOffset{ .from = 1761440400, .offset = 3600 }, // Sun Oct 26 01:00:00 2025
    TimeOffset{ .from = 1743296400, .offset = 7200 }, // Sun Mar 30 01:00:00 2025
    TimeOffset{ .from = 1729990800, .offset = 3600 }, // Sun Oct 27 01:00:00 2024
    TimeOffset{ .from = 1711846800, .offset = 7200 }, // Sun Mar 31 01:00:00 2024
    TimeOffset{ .from = 1698541200, .offset = 3600 }, // Sun Oct 29 01:00:00 2023
    TimeOffset{ .from = 1679792400, .offset = 7200 }, // Sun Mar 26 01:00:00 2023
    TimeOffset{ .from = 1667091600, .offset = 3600 }, // Sun Oct 30 01:00:00 2022
    TimeOffset{ .from = 1648342800, .offset = 7200 }, // Sun Mar 27 01:00:00 2022
    TimeOffset{ .from = 1635642000, .offset = 3600 }, // Sun Oct 31 01:00:00 2021
    TimeOffset{ .from = 1616893200, .offset = 7200 }, // Sun Mar 28 01:00:00 2021
    TimeOffset{ .from = 1603587600, .offset = 3600 }, // Sun Oct 25 01:00:00 2020
    TimeOffset{ .from = 1585443600, .offset = 7200 }, // Sun Mar 29 01:00:00 2020
    TimeOffset{ .from = 1572138000, .offset = 3600 }, // Sun Oct 27 01:00:00 2019
    TimeOffset{ .from = 1553994000, .offset = 7200 }, // Sun Mar 31 01:00:00 2019
    TimeOffset{ .from = 1540688400, .offset = 3600 }, // Sun Oct 28 01:00:00 2018
    TimeOffset{ .from = 1521939600, .offset = 7200 }, // Sun Mar 25 01:00:00 2018
    TimeOffset{ .from = 1509238800, .offset = 3600 }, // Sun Oct 29 01:00:00 2017
    TimeOffset{ .from = 1490490000, .offset = 7200 }, // Sun Mar 26 01:00:00 2017
    TimeOffset{ .from = 1477789200, .offset = 3600 }, // Sun Oct 30 01:00:00 2016
    TimeOffset{ .from = 0, .offset = 3600 },
};

fn findUnixOffset(unix: i64) i16 {
    for (timeOffsets_Berlin) |to| {
        if (to.from <= unix) {
            return to.offset;
        }
    }
    unreachable;
}

pub fn unix2local(unix: i64) i64 {
    const offset = findUnixOffset(unix);
    return unix + offset - (7 * 3600); //Berlin time -> CST
}

pub const DateTime = struct {
    day: u8,
    month: u8,
    year: u16,
    hour: u8,
    minute: u8,
    second: u8,
};

pub fn timestamp2DateTime(timestamp: i64) DateTime {
    const unixtime = @intCast(u64, timestamp);
    const secondsPerDay = 86400;
    const daysInYear = 365;
    const daysIn4Years = 1461;
    const daysIn100Years = 36524;
    const daysIn400Years = 146097;
    const daysUpTo1970_01_01 = 719468;
    var dayN: u64 = daysUpTo1970_01_01 + unixtime / secondsPerDay;
    var secondsSinceMidnight: u64 = unixtime % secondsPerDay;
    var temp: u64 = 4 * (dayN + daysIn100Years + 1) / daysIn400Years - 1;
    var year = @intCast(u16, 100 * temp);
    dayN -= daysIn100Years * temp + temp / 4;
    temp = 4 * (dayN + daysInYear + 1) / daysIn4Years - 1;
    year += @intCast(u16, temp);
    dayN -= daysInYear * temp + temp / 4;
    var month = @intCast(u8, (5 * dayN + 2) / 153);
    var day = @intCast(u8, dayN - (@intCast(u64, month) * 153 + 2) / 5 + 1);
    month += 3;
    if (month > 12) {
        month -= 12;
        year += 1;
    }
    var hour = @intCast(u8, secondsSinceMidnight / 3600);
    var minutes = @intCast(u8, secondsSinceMidnight % 3600 / 60);
    var seconds = @intCast(u8, secondsSinceMidnight % 60);

    return DateTime{
        .day = day,
        .month = month,
        .year = year,
        .hour = hour,
        .minute = minutes,
        .second = seconds,
    };
}

pub fn printDateTime(dt: DateTime, buf: []u8) ![]u8 {
    return try std.fmt.bufPrint(buf, "{:0>2}/{:0>2}/{:0>2}", .{
        dt.month,
        dt.day,
        (dt.year % 100),
    });
}
pub fn printNowLocal(buf: []u8) ![]u8 {
    return try printDateTime(timestamp2DateTime(unix2local(std.time.timestamp())), buf);
}
pub fn adjustedTimestamp(days: i16) i64 {
    return std.time.timestamp() + @intCast(i64, days) * 24 * 60 * 60;
}
