#!/usr/bin/env python3
"""Regenerate the tiny waveform contract fixture (coremltools 9.0).

This is a deterministic 30/70 gain split, not a trained separation model.
coremltools is a development-only dependency; the iPad app does not use Python.
"""
from pathlib import Path
import coremltools as ct
from coremltools.models.neural_network import NeuralNetworkBuilder
from coremltools.models import datatypes

builder = NeuralNetworkBuilder(
    [('audio', datatypes.Array(1, 2, 8192))],
    [('stems', datatypes.Array(1, 2, 2, 8192))],
    disable_rank5_shape_mapping=True,
    use_float_arraytype=True,
)
builder.add_elementwise(name='vocals', input_names=['audio'], output_name='voice', mode='MULTIPLY', alpha=.3)
builder.add_elementwise(name='music', input_names=['audio'], output_name='music', mode='MULTIPLY', alpha=.7)
builder.add_stack(name='both', input_names=['voice', 'music'], output_name='stems', axis=1)
model = ct.models.MLModel(builder.spec, skip_model_load=True)
model.user_defined_metadata['coverflow.stem_order'] = 'Vocals,Instrumental'
model.user_defined_metadata['coverflow.sample_rate'] = '44100'
model.short_description = 'Cover Flow test fixture: 30/70 waveform split. No trained weights.'
model.save(str(Path(__file__).resolve().parents[1] / 'iPad/Tests/Fixtures/SplitFixture.mlmodel'))
print('Generated deterministic waveform model fixture')
