"""Exports the learned board finder (finder.py's BoardNet) to Core ML for the app:
input 'image' (1,3,256,256) RGB 0..255, the photo letterboxed at the top left on grey 114;
output 'maps' (1,3,64,64), sigmoids: playing area, its 4 corners, its 81 square corners.

    python3 export_finder.py finder1.pt ../../App/Resources/BoardNet.mlpackage
"""
import sys, os
import numpy as np
import torch
import coremltools as ct
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from finder import BoardNet, IN, OUT


class WithSigmoid(torch.nn.Module):
    def __init__(self, net):
        super().__init__(); self.net = net

    def forward(self, x):
        return torch.sigmoid(self.net(x))


net = BoardNet()
net.load_state_dict(torch.load(sys.argv[1], map_location='cpu', weights_only=True))
model = WithSigmoid(net).eval()
example = torch.rand(1, 3, IN, IN) * 255
traced = torch.jit.trace(model, example)
ml = ct.convert(traced, inputs=[ct.TensorType(name='image', shape=(1, 3, IN, IN), dtype=np.float32)],
                outputs=[ct.TensorType(name='maps', dtype=np.float32)],
                minimum_deployment_target=ct.target.iOS17, compute_precision=ct.precision.FLOAT16)
ml.short_description = ('Real chess board finder: from a photo letterboxed into 256 x 256, the playing area, '
                        'its corners and its square corners, at 64 x 64')
ml.author = 'Chess Analyzer; trained on rendered boards (tools/render3d/boards3d.py)'
ml.save(sys.argv[2])
out = ml.predict({'image': example.numpy()})['maps']
ref = model(example).detach().numpy()
print('max difference from PyTorch:', float(np.abs(out - ref).max()), 'output', out.shape)
