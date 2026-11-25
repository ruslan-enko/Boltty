#!/usr/bin/env python3
"""Renders Boltty's interface sounds. They are synthesized here, from nothing
but sine waves, so every sample is Boltty's own — no recording, no library,
no licence to carry.

    scripts/render-sounds.py                    # writes Resources/Sounds/*.wav
    scripts/render-sounds.py --only send        # one moment's files
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
import struct
import wave

RATE = 44_100

SHIPPED = {
    "send": "drop",
    "done": "glass-up",
    "attention": "glass-knock",
    "hum": "exclamation",
}

SEND_VARIANTS = (-1.0, 0.0, 1.0)

HUM_VARIANTS = (-2.0, 0.0, 1.0, 2.0, 3.0)
HUM_LOUDNESS = -31.0

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


def midi(number):
    return 440.0 * 2 ** ((number - 69) / 12)


# (sub, chord) a bar: Em9, Cmaj7, G6, Dsus.
def noise(count, seed):
    out = []
    for _ in range(count):
        seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF
        out.append(seed / 0x3FFFFFFF - 1.0)
    return out


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
    for moment, name in SHIPPED.items():
        if args.only and moment != args.only:
            continue
        make = CANDIDATES[moment][name]
        if moment in ("send", "hum"):
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
