import numpy as np
from pathlib import Path
import json
import shutil

# --- Model Configuration ---
# Define architectural parameters for various models.

def get_llama_style_shapes(config: dict) -> dict:
    """Calculates matrix shapes for Llama-like architectures."""
    hidden_size = config['hidden_size']
    intermediate_size = config['intermediate_size']
    num_heads = config['num_attention_heads']
    num_kv_heads = config.get('num_key_value_heads', num_heads)
    head_dim = hidden_size // num_heads

    return {
        "q_proj": (num_heads * head_dim, hidden_size),
        "k_proj": (num_kv_heads * head_dim, hidden_size),
        "v_proj": (num_kv_heads * head_dim, hidden_size),
        "o_proj": (hidden_size, num_heads * head_dim),
        "gate_proj": (intermediate_size, hidden_size),
        "up_proj": (intermediate_size, hidden_size),
        "down_proj": (hidden_size, intermediate_size)
    }

MODEL_CONFIGS = {
    # ==========================================
    # Baseline Quantized Models (BitNet/Falcon)
    # ==========================================
    "microsoft/bitnet-b1.58-2B-4T": {
        "hidden_size": 2560,
        "intermediate_size": 6912,
        "num_attention_heads": 20,
        "num_key_value_heads": 5,
        "shape_calculator": get_llama_style_shapes,
        "wgt_sparsity": 0.30,  # Native weight sparsity from BitNet training
        "act_sparsity": 0.0,
    },
    
    "1bitLLM/bitnet_b1_58-large": {
        "hidden_size": 1536,
        "intermediate_size": 4096,
        "num_attention_heads": 16,
        "num_key_value_heads": 16,
        "shape_calculator": get_llama_style_shapes,
    },
    
    "1bitLLM/bitnet_b1_58-3B": {
        "hidden_size": 3200,
        "intermediate_size": 8640,
        "num_attention_heads": 32,
        "num_key_value_heads": 32,
        "shape_calculator": get_llama_style_shapes,
    },
    
    "HF1BitLLM/Llama3-8B-1.58-100B-tokens": {
        "hidden_size": 4096,
        "intermediate_size": 14336,
        "num_attention_heads": 32,
        "num_key_value_heads": 8,
        "shape_calculator": get_llama_style_shapes,
    },
    
    "tiiuae/Falcon3-10B-Base": {
        "hidden_size": 3072,
        "intermediate_size": 23040,
        "num_attention_heads": 12,
        "num_key_value_heads": 4,
        "shape_calculator": get_llama_style_shapes,
    },
    
    "tiiuae/Falcon-E-3B-Base": {
        "hidden_size": 3048,
        "intermediate_size": 13312,
        "num_attention_heads": 16,
        "num_key_value_heads": 2,
        "shape_calculator": get_llama_style_shapes,
    },

    # ==========================================
    # Experimental High-Sparsity Evaluators
    # ==========================================
    
    # 1. ReluLLaMA-7B (High ReLU activation sparsity)
    "SparseLLM/ReluLLaMA-7B": {
        "hidden_size": 4096,
        "intermediate_size": 11008,
        "num_attention_heads": 32,
        "num_key_value_heads": 32,
        "shape_calculator": get_llama_style_shapes,
        "sparsity_type": "unstructured",
        "wgt_sparsity": 0.50,  # 50% unstructured weight sparsity
        "act_sparsity": 0.55,  # 55% activation sparsity derived from ReLU
    },

    # 2. ReluLLaMA-70B (Large matrix with 2:4 structured hardware sparsity)
    "SparseLLM/ReluLLaMA-70B": {
        "hidden_size": 8192,
        "intermediate_size": 28672,
        "num_attention_heads": 64,
        "num_key_value_heads": 8,
        "shape_calculator": get_llama_style_shapes,
        "sparsity_type": "2:4", # Enforces 2 zeros out of every 4 consecutive elements
        "act_sparsity": 0.60,   # 60% activation sparsity derived from ReLU
    },

    # 3. ReluFalcon-40B (Aggressive pruning simulation)
    "SparseLLM/ReluFalcon-40B": {
        "hidden_size": 8192,
        "intermediate_size": 32768,
        "num_attention_heads": 64,
        "num_key_value_heads": 8,
        "shape_calculator": get_llama_style_shapes,
        "sparsity_type": "unstructured",
        "wgt_sparsity": 0.65,  # 65% weight pruning ratio
        "act_sparsity": 0.50,  # ReLU activation sparsity
    },
}

class ModelTestDataGenerator:
    """
    Generates test data that simulates a complete matrix-vector multiplication
    for each major weight matrix in a specified transformer model,
    formatted for the Ara testbench.
    """
    def __init__(self, model_name: str, base_output_dir="model_realistic_op_data"):
        if model_name not in MODEL_CONFIGS:
            raise ValueError(f"Model '{model_name}' not found in MODEL_CONFIGS.")
        
        self.model_name = model_name
        self.config = MODEL_CONFIGS[model_name]
        self.matrix_shapes = self.config['shape_calculator'](self.config)
        
        # Sanitize model name for filesystem path
        sanitized_model_name = self.model_name.replace("/", "__")
        self.output_dir = Path(base_output_dir) / sanitized_model_name
        
        self.output_dir.mkdir(parents=True, exist_ok=True)
        print(f"Generator initialized for model: '{self.model_name}'")

    def generate_and_save_op_data(
        self,
        filepath: Path,
        matrix_shape: tuple,
        activation_bits: int = 8,
        weight_bits: int = 2
    ):
        rows, cols = matrix_shape
        
        # Skip generation if matrix is empty or invalid
        if rows == 0 or cols == 0:
            print(f"  -> Skipped {filepath.name} due to invalid shape {matrix_shape}")
            return
            
        total_elements = rows * cols

        # Fetch structural sparsity definitions
        sparsity_type = self.config.get("sparsity_type", "unstructured")
        wgt_sparsity = self.config.get("wgt_sparsity", 0.0)
        act_sparsity = self.config.get("act_sparsity", 0.0)

        # Define value ranges
        act_min, act_max = -(2**(activation_bits - 1)), 2**(activation_bits - 1) - 1
        wgt_min, wgt_max = 0, 2**weight_bits - 1

        # Initialize pseudo-random base distributions
        activation_vector = np.random.randint(low=act_min, high=act_max + 1, size=cols, dtype=np.int64)
        weights_matrix = np.random.randint(low=wgt_min, high=wgt_max + 1, size=(rows, cols), dtype=np.int64)

        # Enforce designated sparsity targets via zero injection
        
        # Enforce activation sparsity profile
        if act_sparsity > 0:
            act_mask = np.random.rand(cols) >= act_sparsity
            activation_vector = activation_vector * act_mask

        # Enforce weight sparsity profile
        if sparsity_type == "unstructured" and wgt_sparsity > 0:
            wgt_mask = np.random.rand(rows, cols) >= wgt_sparsity
            weights_matrix = weights_matrix * wgt_mask
            
        elif sparsity_type == "2:4":
            # Apply 2:4 structured hardware sparsity constraint
            flat_weights = weights_matrix.flatten()
            padded_len = int(np.ceil(len(flat_weights) / 4.0) * 4)
            padded_weights = np.zeros(padded_len, dtype=np.int64)
            padded_weights[:len(flat_weights)] = flat_weights
            
            blocks = padded_weights.reshape(-1, 4)
            for block in blocks:
                keep_indices = np.random.choice(4, 2, replace=False)
                mask = np.zeros(4, dtype=bool)
                mask[keep_indices] = True
                block[~mask] = 0
                
            weights_matrix = blocks.flatten()[:total_elements].reshape(rows, cols)

        # Calculate the true "golden" result of the operation
        result_vector = np.dot(weights_matrix, activation_vector)
        golden_sum = np.sum(result_vector)

        # Prepare the data for the 4-line text file format
        flat_weights = weights_matrix.flatten()
        tiled_activations = np.tile(activation_vector, rows)

        assert len(flat_weights) == total_elements
        assert len(tiled_activations) == total_elements

        # Write the file
        with open(filepath, 'w') as f:
            f.write(f"{total_elements}\n")
            f.write(' '.join(map(str, tiled_activations)) + '\n')
            f.write(' '.join(map(str, flat_weights)) + '\n')
            f.write(f"{golden_sum}\n")
        
        # Log localized empirical sparsity boundaries
        real_act_zero = np.sum(activation_vector == 0) / cols
        real_wgt_zero = np.sum(weights_matrix == 0) / total_elements
        print(f"  -> Generated {filepath.name} ({total_elements:,} pairs)")
        print(f"     [Sparsity Injected] Act Zero: {real_act_zero:.1%} | Wgt Zero: {real_wgt_zero:.1%}")

    def generate_all_for_testbench(self, layers_to_generate: int = 1):
        """Generates a test data file for each type of matrix in the model."""
        print(f"Starting test data generation for {self.model_name} ({layers_to_generate} layer(s)).")
        
        for i in range(layers_to_generate):
            layer_dir = self.output_dir / f"layer_{i:02d}"
            layer_dir.mkdir(exist_ok=True)
            print(f"Processing Layer {i:02d} matrices...")

            for name, shape in self.matrix_shapes.items():
                filepath = layer_dir / f"{name}_testdata.txt"
                self.generate_and_save_op_data(filepath, matrix_shape=shape)

        # --- Save a summary for reference ---
        summary = {
            "model": self.model_name,
            "config": {
                "hidden_size": self.config['hidden_size'],
                "intermediate_size": self.config['intermediate_size'],
                "num_attention_heads": self.config['num_attention_heads'],
                "num_key_value_heads": self.config.get('num_key_value_heads', self.config['num_attention_heads']),
                "sparsity_type": self.config.get('sparsity_type', 'unstructured'),
                "target_wgt_sparsity": self.config.get('wgt_sparsity', 0.0),
                "target_act_sparsity": self.config.get('act_sparsity', 0.0)
            },
            "description": "Test data files simulating full mat-vec ops with Zero Injection.",
            "matrix_shapes": {k: str(v) for k, v in self.matrix_shapes.items()}
        }
        with open(self.output_dir / "summary_and_shapes.json", 'w') as f:
            json.dump(summary, f, indent=4)

# --- Main execution ---
if __name__ == "__main__":
    BASE_OUTPUT_DIRECTORY = "model_realistic_op_data"
    
    # Clean up previous runs if desired
    if Path(BASE_OUTPUT_DIRECTORY).exists():
        print(f"Removing old output directory: {BASE_OUTPUT_DIRECTORY}")
        shutil.rmtree(BASE_OUTPUT_DIRECTORY)

    # Generate test files for all configured models
    for model in MODEL_CONFIGS.keys():
        print(f"\n{'='*40}")
        print(f"   PROCESSING MODEL: {model}")
        print(f"{'='*40}")
        try:
            generator = ModelTestDataGenerator(model_name=model, base_output_dir=BASE_OUTPUT_DIRECTORY)
            generator.generate_all_for_testbench(layers_to_generate=1)
        except Exception as e:
            print(f"An error occurred while processing {model}: {e}")
            
    print(f"\n\nAll models have been processed. Check the '{BASE_OUTPUT_DIRECTORY}' directory.")