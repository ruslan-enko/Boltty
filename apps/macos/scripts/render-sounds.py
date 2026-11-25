#!/usr/bin/env python3
"""Renders Boltty's interface sounds. They are synthesized here, from nothing
but sine waves, so every sample is Boltty's own — no recording, no library,
no licence to carry.

    scripts/render-sounds.py                    # writes Resources/Sounds/*.wav
    scripts/render-sounds.py --only run         # one moment's files, not the music
    scripts/render-sounds.py --candidates DIR   # every candidate, to listen to

Standard library only. The output is 16-bit mono WAV at 44.1 kHz, which both
`AudioServicesCreateSystemSoundID` and `UNNotificationSound(named:)` play.

Loudness is matched to the Mac's own: the loudest 100 ms of Tink, Glass and
Funk measure -21 to -19 dBFS RMS, so a notification sound lands at -21 and the
send sound, heard many times a day, five decibels under it.
"""

import argparse
import math
import os
import shutil
import struct
import subprocess
import wave

RATE = 44_100

SHIPPED = {
    "send": "drop",
    "done": "glass-up",
    "attention": "glass-knock",
    "hum": "exclamation",
    "boom": "boom",
    "bell": "bell",
    "pop": "pop",
    "run": "run",
    "tap": "tap",
}

SEND_VARIANTS = (-1.0, 0.0, 1.0)

HUM_VARIANTS = (-2.0, 0.0, 1.0, 2.0, 3.0)
HUM_LOUDNESS = -31.0

# Semitones from E, so a hit or a bell sits in the music under it.
VARIANT_SHIFTS = {"boom": (0, 3, 5, 7, 8), "bell": (0, 3, 7, 10, 12)}

NOTIFICATION_LOUDNESS = -21.0
SEND_LOUDNESS = -26.0
PEAK_CEILING = -6.0


def note(name):
    """Frequency of a note such as "E6" (A4 = 440 Hz)."""
    steps = {"C": -9, "D": -7, "E": -5, "F": -4, "G": -2, "A": 0, "B": 2}
    letter, rest = name[0], name[1:]
    shift = 0
    while rest and rest[0] in "#b":
        shift += 1 if rest[0] == "#" else -1
        rest = rest[1:]
    octave = int(rest)
    return 440.0 * 2 ** ((steps[letter] + shift + 12 * (octave - 4)) / 12)


def silence(seconds):
    return [0.0] * int(seconds * RATE)


def mix(into, sound, at):
    start = int(at * RATE)
    end = start + len(sound)
    if end > len(into):
        into.extend([0.0] * (end - len(into)))
    for i, value in enumerate(sound):
        into[start + i] += value
    return into


def attack(i, seconds):
    """A raised-cosine onset: a sine started at full level clicks."""
    n = seconds * RATE
    return 0.5 - 0.5 * math.cos(math.pi * i / n) if i < n else 1.0


def tail(samples, seconds=0.02):
    n = int(seconds * RATE)
    for k in range(min(n, len(samples))):
        samples[-1 - k] *= k / n
    return samples


def struck(frequency, partials, length, onset=0.0015, shimmer=0.0):
    """A struck object: inharmonic partials, each ringing down on its own.

    `partials` is (ratio, level, decay seconds). The higher a partial, the
    sooner it is gone, which is what makes a strike read as a strike and not
    as a chord. `shimmer` adds a twin a few cents off the fundamental, the
    slow beating a real glass has because it is never perfectly round.
    """
    out = []
    twin = frequency * (1 + shimmer) if shimmer else None
    for i in range(int(length * RATE)):
        t = i / RATE
        value = 0.0
        for ratio, level, decay in partials:
            value += level * math.exp(-t / decay) * math.sin(2 * math.pi * frequency * ratio * t)
        if twin:
            value += 0.35 * partials[0][1] * math.exp(-t / partials[0][2]) * math.sin(2 * math.pi * twin * t)
        out.append(value * attack(i, onset))
    return tail(out)


GLASS = ((1.0, 1.0, 0.75), (2.32, 0.32, 0.36), (4.25, 0.16, 0.16), (6.63, 0.07, 0.07))
GLASS_SHORT = ((1.0, 1.0, 0.36), (2.32, 0.30, 0.18), (4.25, 0.14, 0.08), (6.63, 0.06, 0.04))
WOOD = ((1.0, 1.0, 0.30), (3.93, 0.22, 0.06), (9.97, 0.05, 0.02))
TICK = ((1.0, 1.0, 0.035), (2.76, 0.45, 0.014), (5.40, 0.18, 0.006))


def sweep(start, end, glide, decay, length, onset=0.002):
    """A sine whose pitch glides exponentially from `start` to `end` over
    `glide` seconds while it decays — a water drop rises, a bubble falls."""
    out = []
    phase = 0.0
    for i in range(int(length * RATE)):
        t = i / RATE
        f = start * (end / start) ** min(t / glide, 1.0)
        phase += 2 * math.pi * f / RATE
        out.append(math.sin(phase) * math.exp(-t / decay) * attack(i, onset))
    return tail(out)


def transpose(semitones):
    return 2 ** (semitones / 12)


VOWELS = {
    "a": (950.0, 1500.0),
    "e": (650.0, 2200.0),
    "i": (420.0, 2700.0),
    "o": (600.0, 1050.0),
    "u": (420.0, 950.0),
    "m": (300.0, 1300.0),   # a closed mouth: a hum, its second ring faint
}


def voice(segments, seed=7, stretch=1.5):
    """A voice from segments of (seconds, vowel from, vowel to, pitch from,
    pitch to, loudness from, loudness to, breath), each `stretch` times as
    long as written: harmonics of the pitch,
    each weighted by how near it stands to the vowel's two resonances, with
    breath — soft noise — for an "h". Glides inside a segment are smooth.
    """
    out = []
    phase = 0.0
    noise = 0.0
    for duration, va, vb, fa, fb, la, lb, breath in segments:
        n = int(duration * stretch * RATE)
        for i in range(n):
            u = i / max(n - 1, 1)
            s_ = u * u * (3 - 2 * u)
            f1 = VOWELS[va][0] + (VOWELS[vb][0] - VOWELS[va][0]) * s_
            f2 = VOWELS[va][1] + (VOWELS[vb][1] - VOWELS[va][1]) * s_
            closed = 0.15 if "m" in (va, vb) and va == vb else 1.0
            f0 = fa * (fb / fa) ** s_
            t = len(out) / RATE
            f0 *= 1 + 0.015 * math.sin(2 * math.pi * 6 * t)
            phase += 2 * math.pi * f0 / RATE
            value = 0.0
            for h in range(1, 14):
                f = f0 * h
                if f > 6000:
                    break
                w = math.exp(-((f - f1) / 160) ** 2) + closed * 0.7 * math.exp(-((f - f2) / 220) ** 2)
                value += (w + 0.03) * math.sin(h * phase) / h ** 0.4
            seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF
            noise = 0.7 * noise + 0.3 * (seed / 0x3FFFFFFF - 1.0)
            loud = la + (lb - la) * s_
            out.append((value * (1 - breath) + noise * breath * 1.6) * loud)
    for i in range(len(out)):
        out[i] *= attack(i, 0.004)
    return tail(out, 0.04)


EXCLAMATIONS = (
    lambda k: voice([
        (0.03, "a", "a", 430 * k, 470 * k, 0.0, 0.6, 0.85),
        (0.09, "a", "a", 470 * k, 610 * k, 0.6, 1.0, 0.1),
        (0.12, "a", "e", 610 * k, 420 * k, 1.0, 0.0, 0.15),
    ]),
    lambda k: voice([
        (0.03, "m", "m", 360 * k, 370 * k, 0.0, 0.7, 0.4),
        (0.10, "m", "m", 370 * k, 380 * k, 0.7, 0.9, 0.0),
        (0.14, "m", "m", 380 * k, 560 * k, 0.9, 0.0, 0.0),
    ]),
    lambda k: voice([
        (0.025, "e", "e", 520 * k, 540 * k, 0.0, 0.5, 0.9),
        (0.06, "e", "e", 560 * k, 500 * k, 0.9, 0.0, 0.1),
        (0.03, "e", "e", 500 * k, 500 * k, 0.0, 0.4, 0.95),
        (0.11, "e", "e", 580 * k, 460 * k, 0.9, 0.0, 0.1),
    ]),
    lambda k: voice([
        (0.02, "o", "o", 420 * k, 450 * k, 0.0, 0.5, 0.8),
        (0.08, "o", "o", 450 * k, 640 * k, 0.5, 1.0, 0.05),
        (0.15, "o", "u", 640 * k, 480 * k, 1.0, 0.0, 0.05),
    ]),
    lambda k: voice([
        (0.03, "i", "i", 480 * k, 500 * k, 0.0, 0.5, 0.85),
        (0.05, "i", "a", 500 * k, 640 * k, 0.5, 1.0, 0.05),
        (0.13, "a", "a", 640 * k, 520 * k, 1.0, 0.0, 0.1),
    ]),
)


def hum(shift=0.0, which=0):
    return EXCLAMATIONS[which % len(EXCLAMATIONS)](transpose(shift))


def soft_noise(length, centre, envelope, damping=1.4, seed=11):
    """Noise through a gentle two-pole lowpass (a state-variable one) whose
    corner follows `centre(u)`, shaped by `envelope(u)`, u from 0 to 1.
    `damping` 1.4 has no peak at the corner; lower, a soft hump. Peaks
    at 1."""
    out = []
    low = mid = 0.0
    n = int(length * RATE)
    for i in range(n):
        u = i / max(n - 1, 1)
        seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF
        x = seed / 0x3FFFFFFF - 1.0
        f = 2 * math.sin(math.pi * centre(u) / RATE)
        low += f * mid
        high = x - low - damping * mid
        mid += f * high
        out.append(low * envelope(u))
    peak = max(abs(v) for v in out) or 1.0
    return tail([v / peak for v in out])


def midi(number):
    return 440.0 * 2 ** ((number - 69) / 12)


def tick_noise(seed=31):
    """The click under each note of a run: noise with its lows taken out,
    a few milliseconds long — the reference's clicks sit at 3–8 kHz."""
    out = []
    previous = 0.0
    n = int(0.012 * RATE)
    for i in range(n):
        seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF
        x = seed / 0x3FFFFFFF - 1.0
        out.append((x - previous) * 0.5 * math.exp(-i / (0.0025 * RATE)))
        previous = x
    return tail(out, 0.003)


def pad_voice(number, start, attack, release, end, gain, length):
    """One note of a soft pad: a few harmonics rolled off, two copies a
    hair apart for width, swelling in over `attack` and out after
    `release`."""
    out = [0.0] * int(length * RATE)
    f = midi(number)
    first = int(start * RATE)
    last = min(len(out), int(end * RATE))
    for detune in (0.9985, 1.0015):
        for h in range(1, 6):
            level = gain * math.exp(-(h - 1) / 1.6) / h
            step = 2 * math.pi * f * h * detune / RATE
            phase = h * 0.7
            for i in range(first, last):
                t = (i - first) / RATE
                rise = min(1.0, t / attack)
                rise = rise * rise * (3 - 2 * rise)
                fall = 1.0
                if i / RATE > release:
                    u = min(1.0, (i / RATE - release) / max(end - release, 1e-3))
                    fall = 1 - u * u * (3 - 2 * u)
                out[i] += level * rise * fall * math.sin(phase)
                phase += step
    return out


BPM = 115.0
BEAT = 60.0 / BPM
BAR = 4 * BEAT
DROP_AT = 14 * BEAT          # `FirstRunShowController.musicDrop`
MUSIC_LENGTH = 54.0
MINOR = (64, 67, 69, 71, 74, 76, 79, 81, 83, 86)     # E minor pentatonic
# (sub, chord) a bar: Em9, Cmaj7, G6, Dsus.
PROGRESSION = (
    (28, (59, 62, 66, 67)),
    (36, (59, 62, 64, 67)),
    (31, (59, 62, 64, 69)),
    (38, (57, 62, 64, 67)),
)


def noise(count, seed):
    out = []
    for _ in range(count):
        seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF
        out.append(seed / 0x3FFFFFFF - 1.0)
    return out


def noise_burst(length, decay, seed):
    out = []
    previous = 0.0
    for i, x in enumerate(noise(int(length * RATE), seed)):
        out.append((x - previous) * 0.5 * math.exp(-i / (decay * RATE)))
        previous = x
    return tail(out, 0.005)


def ring(frequency, decay, length, gain=1.0):
    step = 2 * math.pi * frequency / RATE
    return [gain * math.sin(step * i) * math.exp(-i / (decay * RATE)) for i in range(int(length * RATE))]


def click(shift=0.0, seed=41):
    """Dry: two short rings and a grain of noise."""
    k = transpose(shift)
    out = ring(860 * k, 0.010, 0.07)
    mix(out, ring(2015 * k, 0.007, 0.05, 0.75), 0.0)
    mix(out, ring(4800 * k, 0.003, 0.02, 0.3), 0.0)
    grain = noise(int(0.012 * RATE), seed)
    mix(out, [0.55 * v * math.exp(-i / (0.0018 * RATE)) for i, v in enumerate(grain)], 0.0)
    return tail([v * attack(i, 0.0004) for i, v in enumerate(out)], 0.01)


def snap(seed=43):
    out = []
    low = mid = 0.0
    for i, x in enumerate(noise(int(0.2 * RATE), seed)):
        f = 2 * math.sin(math.pi * 1900 / RATE)
        low += f * mid
        high = x - low - 0.5 * mid
        mid += f * high
        out.append(mid * math.exp(-i / (0.035 * RATE)) * attack(i, 0.001))
    return tail(out)


def boom(shift=0.0, which=0, number=28, length=1.5, decay=0.42):
    """A hit and a long sub under it, driven so a laptop still says it."""
    f = midi(number + shift)
    out = []
    phase = 0.0
    for i in range(int(length * RATE)):
        t = i / RATE
        phase += 2 * math.pi * (f + 92 * math.exp(-t / 0.032)) / RATE
        body = math.sin(phase) * math.exp(-t / decay)
        out.append(math.tanh(2.6 * body) * 0.9 * attack(i, 0.0015))
    mix(out, [0.5 * v for v in click(-5)], 0.0)
    return tail(out, 0.08)


def glide(numbers, each, slide=0.045, length=None, decay=0.5):
    """One note sliding from step to step, a little glassy."""
    length = length or each * len(numbers) + 0.2
    out = []
    phase = 0.0
    f = midi(numbers[0] + 1.5)
    for i in range(int(length * RATE)):
        t = i / RATE
        index = min(int(t / each), len(numbers) - 1)
        f += (midi(numbers[index]) - f) / (slide * RATE)
        phase += 2 * math.pi * f / RATE
        step = t - index * each
        env = math.exp(-step / decay) * (attack(i, 0.004) if index == 0 else 1.0)
        out.append(env * (math.sin(phase) + 0.28 * math.sin(2 * phase) + 0.12 * math.sin(3 * phase)))
    return tail(out, 0.06)


def stab(numbers, length):
    """A low chord, soft-edged, held short."""
    out = [0.0] * int((length + 0.06) * RATE)
    for number in numbers:
        for detune in (0.997, 1.003):
            step = 2 * math.pi * midi(number) * detune / RATE
            for h in range(1, 6):
                gain = math.exp(-(h - 1) / 1.2) / h
                for i in range(len(out)):
                    t = i / RATE
                    fall = 1.0 if t < length else max(0.0, 1 - (t - length) / 0.06)
                    out[i] += gain * fall * math.sin(step * h * i + number) * (0.55 + 0.45 * math.exp(-t / 0.08))
    return [v * attack(i, 0.008) for i, v in enumerate(out)]


def bell(shift=0.0, which=0):
    """One soft bell that is left to ring."""
    f = midi(76 + shift)
    out = []
    for i in range(int(2.6 * RATE)):
        t = i / RATE
        value = (math.exp(-t / 0.8) * math.sin(2 * math.pi * f * t)
                 + 0.22 * math.exp(-t / 0.5) * math.sin(2 * math.pi * f * 2.003 * t)
                 + 0.1 * math.exp(-t / 0.14) * math.sin(2 * math.pi * f * 5.4 * t))
        out.append(value * attack(i, 0.006))
    return tail(room(out, 0.3)[:len(out)], 0.3)


def pop(shift=0.0, which=0):
    """A face arriving: a blip that lands on its note."""
    f = midi(MINOR[(which * 2 + 1) % len(MINOR)])
    out = []
    phase = 0.0
    for i in range(int(0.24 * RATE)):
        t = i / RATE
        phase += 2 * math.pi * f * (1 - 0.32 * math.exp(-t / 0.018)) / RATE
        out.append((math.sin(phase) + 0.25 * math.sin(2 * phase)) * math.exp(-t / 0.055) * attack(i, 0.002))
    mix(out, [0.2 * v for v in click(which - 2)], 0.0)
    return tail(out)


def run(shift=0.0, which=0):
    """A ladder of ticks, climbing evenly in pitch, quickening a little."""
    out = []
    low, high, count = 330.0 * transpose(which), 2100.0 * transpose(which), 18
    for index in range(count):
        u = index / (count - 1)
        f = low * (high / low) ** u
        rung = ring(f, 0.020, 0.10)
        mix(rung, ring(f * 2, 0.008, 0.05, 0.35), 0.0)
        mix(rung, [0.25 * v for v in tick_noise(seed=51 + index)], 0.0)
        level_ = 0.45 + 0.55 * u
        mix(out, [level_ * v * attack(i, 0.0008) for i, v in enumerate(rung)], 1.15 * (u - 0.12 * u * u))
    return tail(out, 0.05)


def tap(shift=0.0, seed=23):
    """A key, typed: the groove's click, small and dry."""
    out = click(shift, seed)
    return tail([v * math.exp(-i / (0.012 * RATE)) for i, v in enumerate(out)][:int(0.045 * RATE)], 0.01)


def room(samples, wet):
    """Four combs and two all-passes: the space round the pad and the bell."""
    total = [0.0] * len(samples)
    for delay, feedback in ((1557, 0.84), (1617, 0.83), (1491, 0.85), (1422, 0.86)):
        line = [0.0] * delay
        at = 0
        damp = 0.0
        for i, x in enumerate(samples):
            y = line[at]
            damp = 0.6 * y + 0.4 * damp
            line[at] = x + damp * feedback
            at = (at + 1) % delay
            total[i] += y * 0.25
    for delay in (225, 556):
        line = [0.0] * delay
        at = 0
        for i, x in enumerate(total):
            y = line[at]
            total[i] = y - x * 0.5
            line[at] = x + total[i] * 0.5
            at = (at + 1) % delay
    return [x + wet * y for x, y in zip(samples, total)]


def rumble(length, seed=61):
    out = []
    a = b = 0.0
    for i, x in enumerate(noise(int(length * RATE), seed)):
        a += 0.011 * (x - a)
        b += 0.011 * (a - b)
        out.append(b * 9 * (0.75 + 0.25 * math.sin(2 * math.pi * 0.23 * i / RATE)))
    return out


def opening(length):
    """Before the beat: a dark pad opening, a rumble, one bell."""
    out = [0.0] * int(length * RATE)
    for number, gain in ((40, 0.05), (47, 0.07), (52, 0.09), (59, 0.14), (62, 0.13), (66, 0.12), (71, 0.11)):
        mix(out, pad_voice(number, 0.15, 2.6, length - 0.9, length, gain, length), 0.0)
    for k, number in enumerate((76, 78, 83)):
        mix(out, pad_voice(number, 2.6 + 0.6 * k, 1.4, length - 1.0, length, 0.07, length), 0.0)
    mix(out, [0.42 * v for v in bell()], 1.45)
    out = room(out, 0.45)
    air_ = soft_noise(length, lambda u: 900 + 2600 * u, lambda u: 0.3 + 0.7 * u, seed=67)
    for i, v in enumerate(air_[:len(out)]):
        out[i] += 0.035 * v
    low = rumble(length)
    n = len(low)
    for i in range(n):
        u = i / n
        out[i] += 0.9 * low[i] * min(1, u * 4) * (0.55 + 0.45 * u)
    return out[:n]


def swell(length, seed=71):
    """Air rising into a hit."""
    sound = soft_noise(length, lambda u: 200 + 5200 * u ** 2, lambda u: u ** 2.2, damping=1.0, seed=seed)
    return sound


def ending(length=9.0):
    """The sky again: the last hit, the pad, a bell over it."""
    out = [0.0] * int(length * RATE)
    for number, gain in ((40, 0.28), (47, 0.24), (55, 0.22), (59, 0.20), (62, 0.14), (67, 0.10), (74, 0.06)):
        mix(out, pad_voice(number, 0.0, 0.35, 3.6, length, gain, length), 0.0)
    mix(out, [0.5 * v for v in bell(3)], 0.0)
    mix(out, [0.4 * v for v in bell(-2)], 1.5 * BEAT)
    mix(out, [0.35 * v for v in bell(7)], 3 * BEAT)
    out = room(out, 0.4)[:int(length * RATE)]
    mix(out, [0.75 * v for v in boom(length=2.4, decay=0.8)], 0.0)
    return tail(out[:int(length * RATE)], 2.5)


def show_music():
    n = int(MUSIC_LENGTH * RATE)
    tones = [0.0] * n
    hits = [0.0] * n
    subs = []

    def put(into, sound, at, gain=1.0):
        start = int(at * RATE)
        for i, v in enumerate(sound):
            if start + i >= n:
                break
            into[start + i] += gain * v

    intro = opening(DROP_AT + 0.35)
    put(hits, swell(2.2), DROP_AT - 2.2, 0.16)

    clicks = [click(s, 41 + i) for i, s in enumerate((-2, 0, 0, 3))]
    snapped = snap()
    hiss = [v * 1.4 for v in noise_burst(0.07, 0.016, 47)]
    booms = {root: boom(number=root) for root, _ in PROGRESSION}
    short = {root: boom(number=root, length=0.5, decay=0.13) for root, _ in PROGRESSION}
    chords = {c: stab(c, BEAT * 0.72) for _, c in PROGRESSION}
    lead = glide((78, 76, 74, 71), BEAT * 0.5, decay=0.4)
    answer = glide((74, 71, 69), BEAT * 0.75, decay=0.55)
    ping = [0.6 * v for v in bell(7)]
    ladder = run()

    bars = int((MUSIC_LENGTH - DROP_AT) / BAR)
    for bar in range(bars):
        at = DROP_AT + bar * BAR
        root, chord = PROGRESSION[bar % 4]
        sparse = bar < 2
        bare = bar in (6, 7, 14, 15)
        full = not sparse and not bare
        eighth = BEAT / 2
        for step in (0, 3, 6):
            if sparse and step == 3:
                continue
            where = at + step * eighth
            if bare:
                if step == 0:
                    put(hits, booms[root], where, 0.6)
                    subs.append(where)
                continue
            put(hits, booms[root] if step == 0 else short[root], where, 0.72 if step == 0 else 0.55)
            subs.append(where)
        for step in range(16):
            if step % 2 == 1 and not (full and step in (3, 7, 11, 13)):
                continue
            strong = step in (0, 6, 12)
            put(hits, clicks[step % 4], at + step * BEAT / 4, (1.15 if strong else 0.65) * (0.8 if bare else 1.0))
        if not sparse:
            for step in range(16):
                put(hits, hiss, at + step * BEAT / 4, 0.5 if step % 4 == 2 else 0.22)
            for beat in (1, 3):
                put(hits, snapped, at + beat * BEAT, 0.55 if bare else 1.0)
        if not sparse:
            for step in ((0, 3, 6) if full else (0, 6)):
                put(tones, chords[chord], at + step * eighth, 0.15)
        if bar % 2 == 0:
            put(tones, ping, at, 0.26)
        if full and bar % 4 == 2:
            put(tones, lead, at + BEAT, 0.34)
        if full and bar % 4 == 0 and bar > 2:
            put(tones, answer, at + 2 * BEAT, 0.30)
        if bar in (1, 7, 15):
            put(tones, ladder, at + BAR - 1.1, 0.40)
            put(hits, swell(1.6, 73 + bar), at + BAR - 1.6, 0.22)
    tones = room(tones[int(DROP_AT * RATE):], 0.3)[:n - int(DROP_AT * RATE)]
    head = [0.0] * n
    put(head, intro, 0.0, 0.55)
    out = head[:]
    start = int(DROP_AT * RATE)
    duck = [1.0] * n
    for k in subs:
        first = int(k * RATE)
        for i in range(int(0.3 * RATE)):
            if first + i >= n:
                break
            duck[first + i] = min(duck[first + i], 1 - 0.5 * math.exp(-i / (0.10 * RATE)))
    for i in range(n):
        tone = tones[i - start] if i >= start else 0.0
        out[i] = (out[i] if i < start else 0.0) + tone * duck[i] + hits[i]
        out[i] = math.tanh(0.9 * out[i])
    fade = int(3.0 * RATE)
    for i in range(fade):
        out[n - fade + i] *= 1 - i / fade
    return out


def encode(folder, name, samples, loudness):
    """AAC where `afconvert` is there (a tenth of the size), otherwise WAV."""
    wav = os.path.join(folder, f"{name}.wav")
    write(wav, level(samples, loudness))
    if shutil.which("afconvert"):
        m4a = os.path.join(folder, f"{name}.m4a")
        subprocess.run(["afconvert", "-f", "m4af", "-d", "aac", "-b", "128000", wav, m4a], check=True)
        os.remove(wav)


def write_music(folder):
    encode(folder, "show-music", show_music(), -15.0)
    encode(folder, "show-ending", ending(), -19.0)


def drop(shift=0.0):
    """A drop falling into water: the bubble's note rises as it closes."""
    k = transpose(shift)
    body = sweep(430 * k, 1300 * k, 0.055, 0.045, 0.22)
    under = [0.18 * v for v in sweep(260 * k, 520 * k, 0.04, 0.025, 0.12)]
    return mix(body, under, 0.0)


def bubble(shift=0.0):
    k = transpose(shift)
    return sweep(950 * k, 320 * k, 0.045, 0.05, 0.22)


def tick(shift=0.0):
    k = transpose(shift)
    return struck(2600 * k, TICK, 0.18, onset=0.0008)


def glass_up():
    """Two glass notes a major third apart, rising: something is finished."""
    out = struck(note("E6"), GLASS, 1.6, shimmer=0.0025)
    return mix(out, [0.9 * v for v in struck(note("G#6"), GLASS, 1.6, shimmer=0.0025)], 0.11)


def glass_ring():
    return struck(note("G6"), GLASS, 1.9, shimmer=0.002)


def wood_up():
    out = struck(note("G5"), WOOD, 0.9)
    return mix(out, struck(note("C6"), WOOD, 0.9), 0.10)


def glass_knock():
    """The same glass note struck twice: not an ending, a call."""
    out = struck(note("D6"), GLASS_SHORT, 1.0, shimmer=0.002)
    return mix(out, struck(note("D6"), GLASS_SHORT, 1.0, shimmer=0.002), 0.14)


def glass_bell():
    """Down a major third, as a doorbell goes."""
    out = struck(note("G6"), GLASS, 1.5, shimmer=0.0025)
    return mix(out, [0.95 * v for v in struck(note("D#6"), GLASS, 1.5, shimmer=0.0025)], 0.16)


def wood_knock():
    out = []
    for n, at in enumerate((0.0, 0.09, 0.18)):
        mix(out, [(0.8 if n < 2 else 1.0) * v for v in struck(note("A5"), WOOD, 0.6)], at)
    return out


CANDIDATES = {
    "send": {"drop": drop, "bubble": bubble, "tick": tick},
    "done": {"glass-up": glass_up, "glass-ring": glass_ring, "wood-up": wood_up},
    "attention": {"glass-knock": glass_knock, "glass-bell": glass_bell, "wood-knock": wood_knock},
    "hum": {"exclamation": hum},
    "boom": {"boom": boom},
    "bell": {"bell": bell},
    "pop": {"pop": pop},
    "run": {"run": run},
    "tap": {"tap": tap},
}


def loudest_window_db(samples, seconds=0.1):
    n = int(seconds * RATE)
    best = 0.0
    for i in range(0, max(1, len(samples) - n), n // 4):
        window = samples[i:i + n]
        best = max(best, sum(v * v for v in window) / max(1, len(window)))
    return 10 * math.log10(best) if best > 0 else -120.0


def level(samples, loudness):
    gain = 10 ** ((loudness - loudest_window_db(samples)) / 20)
    peak = max(abs(v) for v in samples) * gain
    ceiling = 10 ** (PEAK_CEILING / 20)
    if peak > ceiling:
        gain *= ceiling / peak
    return [v * gain for v in samples]


def write(path, samples):
    with wave.open(path, "wb") as out:
        out.setnchannels(1)
        out.setsampwidth(2)
        out.setframerate(RATE)
        out.writeframes(b"".join(
            struct.pack("<h", max(-32767, min(32767, round(v * 32767)))) for v in samples
        ))


def loudness_for(moment):
    return {
        "send": SEND_LOUDNESS, "hum": HUM_LOUDNESS,
        "boom": -20.0, "bell": -28.0, "pop": -27.0, "run": -29.0, "tap": -35.0,
    }.get(moment, NOTIFICATION_LOUDNESS)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--candidates", metavar="DIR")
    parser.add_argument("--only", metavar="MOMENT", choices=sorted(SHIPPED))
    args = parser.parse_args()

    if args.candidates:
        os.makedirs(args.candidates, exist_ok=True)
        for moment, sounds in CANDIDATES.items():
            for name, make in sounds.items():
                path = os.path.join(args.candidates, f"{moment}-{name}.wav")
                write(path, level(make(), loudness_for(moment)))
                print(path)
        return

    here = os.path.dirname(os.path.abspath(__file__))
    folder = os.path.join(here, "..", "Resources", "Sounds")
    os.makedirs(folder, exist_ok=True)
    if not args.only:
        write_music(folder)
    for moment, name in SHIPPED.items():
        if args.only and moment != args.only:
            continue
        make = CANDIDATES[moment][name]
        if moment in ("run", "pop", "boom", "bell"):
            for index in range(5):
                write(os.path.join(folder, f"{moment}-{index + 1}.wav"), level(make(VARIANT_SHIFTS.get(moment, (0,) * 5)[index], index), loudness_for(moment)))
        elif moment in ("send", "hum", "tap"):
            middle = make(0.0)
            gain = max(abs(v) for v in level(middle, loudness_for(moment))) / max(abs(v) for v in middle)
            variants = SEND_VARIANTS if moment == "send" else HUM_VARIANTS
            for index, shift in enumerate(variants, start=1):
                sound = make(shift, index - 1) if moment == "hum" else make(shift)
                if moment == "hum":
                    sound = level(sound, HUM_LOUDNESS)
                    write(os.path.join(folder, f"{moment}-{index}.wav"), sound)
                else:
                    write(os.path.join(folder, f"{moment}-{index}.wav"), [v * gain for v in sound])
        else:
            write(os.path.join(folder, f"{moment}.wav"), level(make(), NOTIFICATION_LOUDNESS))
    print(os.path.normpath(folder))


if __name__ == "__main__":
    main()
