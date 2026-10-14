"""Slaney mel filter bank, matching librosa 0.11's default filters.mel.

Adapted from librosa (ISC; see LIBROSA-LICENSE.txt). Only the default
Slaney path used by this model is needed; no audio resampling or training helpers.
"""
import numpy as np


def mel(*, sr, n_fft, n_mels):
    def hz_to_mel(freq):
        return freq / (200 / 3) if freq < 1000 else 15 + np.log(freq / 1000) / (np.log(6.4) / 27)
    values = np.linspace(hz_to_mel(0), hz_to_mel(float(sr) / 2), int(n_mels) + 2)
    frequencies = (200 / 3) * values
    logarithmic = values >= 15
    frequencies[logarithmic] = 1000 * np.exp((np.log(6.4) / 27) * (values[logarithmic] - 15))
    bins = np.fft.rfftfreq(n_fft, d=1 / sr)
    differences = np.diff(frequencies)
    ramps = np.subtract.outer(frequencies, bins)
    weights = np.zeros((int(n_mels), 1 + n_fft // 2), dtype=np.float32)
    for i in range(int(n_mels)):
        weights[i] = np.maximum(0, np.minimum(-ramps[i] / differences[i], ramps[i + 2] / differences[i + 1]))
    weights *= (2 / (frequencies[2:] - frequencies[:-2]))[:, None]
    return weights
