"""Exports SquareNet to Core ML: input 'squares' (64,1,32,32) grey 0..255, output 'probabilities' (64,13)."""
import sys
import numpy as np
import torch
import coremltools as ct
import os; sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from train import SquareNet

class WithSoftmax(torch.nn.Module):
    def __init__(self, net):
        super().__init__(); self.net = net
    def forward(self, x):
        return torch.softmax(self.net(x), dim=1)

net = SquareNet(); net.load_state_dict(torch.load(sys.argv[1], map_location='cpu')); net.eval()
model = WithSoftmax(net).eval()
example = torch.rand(64, 1, 32, 32) * 255
traced = torch.jit.trace(model, example)
ml = ct.convert(traced, inputs=[ct.TensorType(name='squares', shape=(64, 1, 32, 32), dtype=np.float32)],
                outputs=[ct.TensorType(name='probabilities', dtype=np.float32)],
                minimum_deployment_target=ct.target.iOS17, compute_precision=ct.precision.FLOAT16)
ml.short_description = 'Chess diagram square classifier: empty, wP wN wB wR wQ wK, bP bN bB bR bQ bK'
ml.author = 'Chess Analyzer; trained on synthetic diagrams (tools/diagram)'
ml.save(sys.argv[2])
# Check the conversion against PyTorch.
out = ml.predict({'squares': example.numpy()})['probabilities']
ref = model(example).detach().numpy()
print('max difference from PyTorch:', float(np.abs(out - ref).max()))
