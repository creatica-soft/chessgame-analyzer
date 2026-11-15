"""Exports PieceNet to Core ML: input 'crops' (64,3,96,48) RGB 0..255, one tall crop per square
(a1, b1, ..., h8), output 'probabilities' (64,13): empty, wP wN wB wR wQ wK, bP bN bB bR bQ bK."""
import sys, os
import numpy as np
import torch
import coremltools as ct
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from train3d import load


class WithSoftmax(torch.nn.Module):
    def __init__(self, net):
        super().__init__(); self.net = net

    def forward(self, x):
        return torch.softmax(self.net(x), dim=1)


net = load(sys.argv[1])
model = WithSoftmax(net).eval()
example = torch.rand(64, 3, 96, 48) * 255
traced = torch.jit.trace(model, example)
ml = ct.convert(traced, inputs=[ct.TensorType(name='crops', shape=(64, 3, 96, 48), dtype=np.float32)],
                outputs=[ct.TensorType(name='probabilities', dtype=np.float32)],
                minimum_deployment_target=ct.target.iOS17, compute_precision=ct.precision.FLOAT16)
ml.short_description = 'Real chess board piece classifier, one tall crop per square: empty, wP wN wB wR wQ wK, bP bN bB bR bQ bK'
ml.author = 'Chess Analyzer; trained on video of a board (tools/board3d)'
ml.save(sys.argv[2])
out = ml.predict({'crops': example.numpy()})['probabilities']
ref = model(example).detach().numpy()
print('max difference from PyTorch:', float(np.abs(out - ref).max()))
