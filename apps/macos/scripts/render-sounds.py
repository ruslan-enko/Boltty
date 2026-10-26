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

# Where the shipped sounds go, and which candidate each one is.
SHIPPED = {
    "send": "drop",
    "done": "glass-up",
    "attention": "glass-knock",
    "hum": "exclamation",
    "whoosh": "breath",
    "run": "run",
    "tap": "tap",
}

# How far apart, in semitones, the send sound's variants stand. Played in turn
# at random, so a sound heard fifty times a day is never quite the same twice.
SEND_VARIANTS = (-1.0, 0.0, 1.0)

# The first run's faces each exclaim in a voice of their own: one
# exclamation a face (`EXCLAMATIONS`), at a pitch of its own in semitones.
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


# A small, high voice's vowels: (F1, F2) in Hz, a child's spacing lifted a
# little, since the speakers are toys.
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


# What each face of the first run says as it shows its feeling, as the
# characters in Zelda do — a breath, a vowel, a turn of pitch, no words.
# In the faces' order; `hum(shift)` takes the voice up or down.
EXCLAMATIONS = (
    # "Hah!" — up, and down with a grin.
    lambda k: voice([
        (0.03, "a", "a", 430 * k, 470 * k, 0.0, 0.6, 0.85),
        (0.09, "a", "a", 470 * k, 610 * k, 0.6, 1.0, 0.1),
        (0.12, "a", "e", 610 * k, 420 * k, 1.0, 0.0, 0.15),
    ]),
    # "Hm?" — a closed-mouth question.
    lambda k: voice([
        (0.03, "m", "m", 360 * k, 370 * k, 0.0, 0.7, 0.4),
        (0.10, "m", "m", 370 * k, 380 * k, 0.7, 0.9, 0.0),
        (0.14, "m", "m", 380 * k, 560 * k, 0.9, 0.0, 0.0),
    ]),
    # "Heh-heh" — two quick laughs.
    lambda k: voice([
        (0.025, "e", "e", 520 * k, 540 * k, 0.0, 0.5, 0.9),
        (0.06, "e", "e", 560 * k, 500 * k, 0.9, 0.0, 0.1),
        (0.03, "e", "e", 500 * k, 500 * k, 0.0, 0.4, 0.95),
        (0.11, "e", "e", 580 * k, 460 * k, 0.9, 0.0, 0.1),
    ]),
    # "Oh!" — surprise, up and over.
    lambda k: voice([
        (0.02, "o", "o", 420 * k, 450 * k, 0.0, 0.5, 0.8),
        (0.08, "o", "o", 450 * k, 640 * k, 0.5, 1.0, 0.05),
        (0.15, "o", "u", 640 * k, 480 * k, 1.0, 0.0, 0.05),
    ]),
    # "Hyah!" — a jump's shout.
    lambda k: voice([
        (0.03, "i", "i", 480 * k, 500 * k, 0.0, 0.5, 0.85),
        (0.05, "i", "a", 500 * k, 640 * k, 0.5, 1.0, 0.05),
        (0.13, "a", "a", 640 * k, 520 * k, 1.0, 0.0, 0.1),
    ]),
)


def hum(shift=0.0, which=0):
    return EXCLAMATIONS[which % len(EXCLAMATIONS)](transpose(shift))


def air(shift=0.0, length=0.34, seed=11):
    """Something passing close by, fast: soft noise through a resonance that
    sweeps up and back down, swelling in the middle — a whoosh, no tone."""
    k = transpose(shift)
    out = []
    y1 = y2 = 0.0
    n = int(length * RATE)
    for i in range(n):
        u = i / max(n - 1, 1)
        # Up quickly, down slower, as a thing nearing and leaving does.
        centre = (500 + 2600 * math.sin(math.pi * min(1.0, u * 1.25)) ** 1.5) * k
        r = 0.985
        w = 2 * math.pi * centre / RATE
        seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF
        x = seed / 0x3FFFFFFF - 1.0
        y = (1 - r) * x + 2 * r * math.cos(w) * y1 - r * r * y2
        y2, y1 = y1, y
        envelope = math.sin(math.pi * u) ** 2.2
        out.append(y * envelope * 30)
    return tail(out)


# What passes as a face or a window flies. A narrow resonance sweeping up to
# 3 kHz, where the ear is keenest, whistles in the hiss and grates when heard
# a dozen times in the show. These are broad and low: no resonance to whistle,
# little above 1.5 kHz.

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


def rise_and_fall(u, at=0.4):
    """Swells to its top at `at` and away after, smoothly at both ends."""
    return math.sin(math.pi * u ** (math.log(0.5) / math.log(at))) ** 2


def breath(shift=0.0, length=0.38, seed=11):
    """A soft breath of air past the ear — a lowpass opening to 1.4 kHz and
    closing again, swelling in its first half: "fff", no whistle."""
    k = transpose(shift)
    return soft_noise(length,
                      lambda u: (260 + 1100 * math.sin(math.pi * u) ** 1.5) * k,
                      lambda u: rise_and_fall(u, 0.4), seed=seed)


def silk(shift=0.0, length=0.34, seed=13):
    """A swish of cloth, as a plush toy makes going by: the lowpass with a
    soft hump at its corner, sweeping 0.45 to 1.5 kHz and back — more
    texture than `breath`, still no whistle."""
    k = transpose(shift)
    return soft_noise(length,
                      lambda u: (450 + 1050 * math.sin(math.pi * u) ** 1.5) * k,
                      lambda u: rise_and_fall(u, 0.4), damping=0.8, seed=seed)


def puff(shift=0.0, seed=17):
    """A short puff of air and a soft landing, as a cushion is set down:
    lowpassed noise, and under its end a low thump falling 170 to 115 Hz."""
    k = transpose(shift)
    out = [0.8 * v for v in soft_noise(0.22,
                                       lambda u: (380 + 750 * math.sin(math.pi * u)) * k,
                                       lambda u: rise_and_fall(u, 0.3), seed=seed)]
    mix(out, [0.45 * v for v in sweep(170 * k, 115 * k, 0.06, 0.045, 0.16, onset=0.006)], 0.12)
    return tail(out)


# The first run's music (after the feel of Dia's intro — its
# shape measured, nothing of it copied): a chord that swells as the night
# breaks, and a run of plucked notes up the F major pentatonic as each scene
# arrives, each run a step higher than the last.

PLUCK = ((1.0, 1.0, 0.55), (2.0, 0.32, 0.22), (3.0, 0.12, 0.11), (4.2, 0.05, 0.05))
PENTATONIC = (0, 2, 5, 7, 9)  # from C: C D F G A, all in F major


def midi(number):
    return 440.0 * 2 ** ((number - 69) / 12)


def pentatonic_from(start, count):
    """`count` notes of the F pentatonic, rising from MIDI `start`."""
    notes = []
    n = start
    while len(notes) < count:
        if n % 12 in PENTATONIC:
            notes.append(n)
        n += 1
    return notes


def mallet(number, gain=1.0, length=0.45):
    """A soft mallet on a wooden bar: the note and a little of its octave,
    gone in a fraction of a second — no inharmonic partials, nothing that
    rings on."""
    f = midi(number)
    out = []
    for i in range(int(length * RATE)):
        t = i / RATE
        value = (math.exp(-t / 0.12) * math.sin(2 * math.pi * f * t)
                 + 0.14 * math.exp(-t / 0.05) * math.sin(4 * math.pi * f * t))
        out.append(gain * value * attack(i, 0.004))
    return tail(out)


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


def run(shift=0.0, which=0):
    """A run up the pentatonic on soft mallets — fourteen notes, even, from
    low to three octaves up in a second, a second voice two steps over
    the first, and a soft click on every note, as the reference's runs
    are measured to go. `which` starts each a step higher."""
    notes = pentatonic_from(54 + 2 * which, 16)
    out = []
    for index in range(14):
        at = 0.1 * index * (1 - 0.012 * index)
        swell = 0.55 + 0.45 * index / 13
        mix(out, mallet(notes[index], swell), at)
        mix(out, mallet(notes[index + 2], 0.3 * swell), at + 0.012)
        mix(out, [0.5 * v for v in tick_noise(seed=31 + index)], at)
    return tail(out, 0.05)


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


def dawn(shift=0.0, which=0):
    """The night breaking: a held C swelling, opening at the sunrise into F
    with its ninth, a shimmer of high notes over it, and a breath of air
    rising into the moment it opens."""
    length = 7.5
    out = [0.0] * int(length * RATE)
    def add(sound):
        for i, v in enumerate(sound):
            out[i] += v
    for number, gain in ((48, 0.5), (60, 0.35), (46, 0.18)):
        add(pad_voice(number, 0.0, 1.6, 1.9, 3.0, gain, length))
    for number, gain in ((41, 0.45), (48, 0.4), (53, 0.42), (55, 0.28), (60, 0.3), (65, 0.25),
                         (67, 0.18), (72, 0.14)):
        add(pad_voice(number, 1.4, 0.7, 4.6, 7.4, gain, length))
    for k, number in enumerate((77, 81, 84, 89)):
        add(pad_voice(number, 1.9 + 0.25 * k, 0.5, 3.6 + 0.2 * k, 6.0, 0.05, length))
    breath = air(0.0, length=1.2, seed=5)
    mix(out, [0.35 * v for v in breath], 0.6)
    return tail(out, 0.3)


def tap(shift=0.0, seed=23):
    """A key, typed: a few milliseconds of soft noise, a little darker for
    a lower `shift` — a click with no note in it."""
    k = transpose(shift)
    out = []
    smooth = 0.0
    n = int(0.018 * RATE)
    for i in range(n):
        seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF
        x = seed / 0x3FFFFFFF - 1.0
        smooth += (0.35 * k) * (x - smooth)
        out.append(smooth * math.exp(-i / (0.004 * RATE)))
    return tail(out, 0.004)


# --- the first run's music ------------------------------------------------
#
# Under the whole show, after the feel of a promo's track. Its feel was
# measured off
# that recording — about 138 beats a minute, bass, a steady beat, chords
# held over it, fuller in its second half — and none of it taken: this is
# its own groove, in F, so the dawn and the scenes' runs sit in it.

BPM = 138.0
BEAT = 60.0 / BPM
BAR = 4 * BEAT
GROOVE_AT = 2 * BAR          # the beat comes in two bars after the night breaks
MUSIC_LENGTH = 39.0
# (bass, chord) a bar: Fmaj9, Dm9, B-flat maj9, C add9.
PROGRESSION = (
    (41, (57, 60, 64, 67)),
    (38, (57, 60, 64, 65)),
    (46, (57, 62, 65, 72)),
    (48, (55, 60, 62, 67)),
)


def noise_burst(length, decay, seed, bright=True):
    out = []
    previous = 0.0
    for i in range(int(length * RATE)):
        seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF
        x = seed / 0x3FFFFFFF - 1.0
        out.append(((x - previous) if bright else x) * math.exp(-i / (decay * RATE)))
        previous = x
    return out


def kick():
    out = []
    phase = 0.0
    for i in range(int(0.34 * RATE)):
        t = i / RATE
        f = 46 + 84 * math.exp(-t / 0.028)
        phase += 2 * math.pi * f / RATE
        out.append(math.sin(phase) * math.exp(-t / 0.16) * attack(i, 0.001))
    return mix(out, [0.25 * v for v in noise_burst(0.004, 0.001, 3)], 0.0)


def clap(seed=7):
    out = []
    for k, at in enumerate((0.0, 0.011, 0.022)):
        mix(out, [0.6 * v for v in noise_burst(0.16 if k == 2 else 0.02, 0.05 if k == 2 else 0.006, seed + k)], at)
    return tail(out, 0.01)


def hat(open_=False, seed=11):
    return [0.5 * v for v in noise_burst(0.14 if open_ else 0.03, 0.05 if open_ else 0.008, seed)]


def bass(number, length):
    f = midi(number)
    out = []
    for i in range(int(length * RATE)):
        t = i / RATE
        env = math.exp(-t / 0.7) * attack(i, 0.006)
        out.append(env * (math.sin(2 * math.pi * f * t) + 0.25 * math.sin(4 * math.pi * f * t)))
    return tail(out, 0.03)


def keys(number, length=1.5):
    """An electric piano: a sine bent by its own frequency, the bend dying
    fast — a soft bell on the attack, a round note after it."""
    f = midi(number)
    out = []
    w = 2 * math.pi * f / RATE
    for i in range(int(length * RATE)):
        t = i / RATE
        index = 1.4 * math.exp(-t / 0.22)
        out.append(math.sin(w * i + index * math.sin(w * i)) * math.exp(-t / 0.85) * attack(i, 0.004))
    return tail(out, 0.05)


def show_music():
    n = int(MUSIC_LENGTH * RATE)
    drums = [0.0] * n
    tones = [0.0] * n
    kicks = []

    def put(into, sound, at, gain=1.0):
        start = int(at * RATE)
        for i, v in enumerate(sound):
            if start + i >= n:
                break
            into[start + i] += gain * v

    kick_sound, clap_sound = kick(), clap()
    closed, opened = hat(), hat(True)
    bars = int((MUSIC_LENGTH - GROOVE_AT) / BAR)
    outro = bars - 2
    for bar in range(bars):
        at = GROOVE_AT + bar * BAR
        root, chord = PROGRESSION[bar % len(PROGRESSION)]
        fuller = bar >= 12
        if bar < outro:
            # Half time: the kick on one and the and of three, the clap on
            # three once the middle comes; eighths of hat over it.
            for beat in ((0.0, 2.5, 3.25) if fuller else (0.0, 2.5)):
                put(drums, kick_sound, at + beat * BEAT, 0.9)
                kicks.append(at + beat * BEAT)
            if bar >= 6:
                put(drums, clap_sound, at + 2 * BEAT, 0.45)
            for eighth in range(8):
                gain = 0.32 if eighth % 2 else 0.18
                put(drums, opened if (fuller and eighth == 7) else closed, at + eighth * BEAT / 2, gain)
            # The bass on one and the and of two.
            put(tones, bass(root, BEAT * 1.4), at, 0.55)
            put(tones, bass(root + 12 if bar % 2 else root, BEAT * 0.9), at + 1.5 * BEAT, 0.4)
        # The chord on one and, held lighter, on the and of three.
        for k, number in enumerate(chord):
            put(tones, keys(number), at + 0.012 * k, 0.16)
            if bar < outro:
                put(tones, keys(number, 0.9), at + 2.5 * BEAT + 0.012 * k, 0.09)
        # From the middle: a run of the chord's notes up high, sixteenths.
        if 6 <= bar < outro:
            notes = [chord[i % 4] + 12 * (1 + i // 4) for i in range(6)]
            for k, number in enumerate(notes):
                put(tones, mallet(number, 0.5, 0.3), at + (8 + k) * BEAT / 4, 0.12)

    # The chords and the bass give way to each kick, a little: the groove.
    duck = [1.0] * n
    for k in kicks:
        start = int(k * RATE)
        for i in range(int(0.25 * RATE)):
            if start + i >= n:
                break
            duck[start + i] = min(duck[start + i], 1 - 0.35 * math.exp(-i / (0.09 * RATE)))
    out = [d + t * u for d, t, u in zip(drums, tones, duck)]
    # The night breaking, under its first bars.
    put(out, dawn(), 0.0, 0.55)
    # Out over the last three seconds.
    fade = int(3.0 * RATE)
    for i in range(fade):
        out[n - fade + i] *= 1 - i / fade
    return out


def write_music(folder):
    """The music as AAC where `afconvert` is there (a tenth of the size),
    otherwise as WAV."""
    wav = os.path.join(folder, "show-music.wav")
    write(wav, level(show_music(), -26.0))
    if shutil.which("afconvert"):
        m4a = os.path.join(folder, "show-music.m4a")
        subprocess.run(["afconvert", "-f", "m4af", "-d", "aac", "-b", "128000", wav, m4a], check=True)
        os.remove(wav)


# --- the candidates -------------------------------------------------------

def drop(shift=0.0):
    """A drop falling into water: the bubble's note rises as it closes."""
    k = transpose(shift)
    body = sweep(430 * k, 1300 * k, 0.055, 0.045, 0.22)
    # A lower, shorter echo of itself gives the drop a body.
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
    "whoosh": {"breath": breath, "silk": silk, "puff": puff},
    "run": {"run": run},
    "tap": {"tap": tap},
}


# --- levels and files -----------------------------------------------------

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
        "whoosh": -35.0, "run": -27.0, "tap": -38.0,
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
        if moment == "run":
            # Five of each, each its own notes, each levelled alone.
            for index in range(5):
                write(os.path.join(folder, f"{moment}-{index + 1}.wav"), level(make(0.0, index), loudness_for(moment)))
        elif moment in ("send", "hum", "whoosh", "tap"):
            # One gain for every variant, taken from the middle one, so the
            # variants differ in pitch and not in level.
            middle = make(0.0)
            gain = max(abs(v) for v in level(middle, loudness_for(moment))) / max(abs(v) for v in middle)
            variants = SEND_VARIANTS if moment == "send" else HUM_VARIANTS
            for index, shift in enumerate(variants, start=1):
                sound = make(shift, index - 1) if moment == "hum" else make(shift)
                if moment == "hum":
                    # Each exclamation its own level: they differ in shape.
                    sound = level(sound, HUM_LOUDNESS)
                    write(os.path.join(folder, f"{moment}-{index}.wav"), sound)
                else:
                    write(os.path.join(folder, f"{moment}-{index}.wav"), [v * gain for v in sound])
        else:
            write(os.path.join(folder, f"{moment}.wav"), level(make(), NOTIFICATION_LOUDNESS))
    print(os.path.normpath(folder))


if __name__ == "__main__":
    main()
