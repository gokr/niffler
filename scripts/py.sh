# Create a virtual environment in a folder called .venv
python3 -m venv .venv

# Activate it
source .venv/bin/activate

# Now install datasets inside the venv
pip install datasets
pip install "datasets[streaming]"

# Run our script that downloads training data from different sources
python scripts/create-corpus.py
