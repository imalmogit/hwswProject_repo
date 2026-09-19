import os
import re
import sysconfig

from setuptools import setup
from Cython.Build import cythonize

# A --with-pydebug build reports /usr/include/python3.10d as its include
# directory, but on Debian/Ubuntu that holds only the debug pyconfig.h --
# Python.h itself sits in the release directory beside it. Add both.
inc = [sysconfig.get_paths()["include"]]
sibling = re.sub(r"d$", "", inc[0])
if sibling != inc[0] and os.path.isdir(sibling):
    inc.append(sibling)

extensions = cythonize("nbody_core.pyx", language_level=3)
for ext in extensions:
    ext.include_dirs.extend(inc)

setup(ext_modules=extensions)
