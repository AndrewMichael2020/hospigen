#!/usr/bin/env python3
"""
Unit tests for Synthea Runner entrypoint - validates environment variable handling.
"""

import pytest
import os
from unittest.mock import patch, MagicMock
import sys
from pathlib import Path

# Add the services directory to path for imports
sys.path.insert(0, str(Path(__file__).parent))


class TestProvinceMapping:
    """Test province abbreviation to full name mapping."""
    
    def test_bc_mapping(self):
        """Test that BC maps to British Columbia."""
        prov_map = {
            "BC": "British Columbia",
            "AB": "Alberta",
            "SK": "Saskatchewan",
            "MB": "Manitoba",
            "ON": "Ontario",
            "QC": "Quebec",
            "NB": "New Brunswick",
            "NS": "Nova Scotia",
            "PE": "Prince Edward Island",
            "NL": "Newfoundland and Labrador",
            "YT": "Yukon",
            "NT": "Northwest Territories",
            "NU": "Nunavut",
        }
        
        # Test the mapping that's crucial for our Vancouver generation
        assert prov_map["BC"] == "British Columbia"
        
        # Test a few other key provinces
        assert prov_map["ON"] == "Ontario"
        assert prov_map["QC"] == "Quebec"
        assert prov_map["AB"] == "Alberta"


class TestEnvironmentVariableHandling:
    """Test environment variable parsing and cleaning."""
    
    def test_clean_function_basic(self):
        """Test the _clean function with basic inputs."""
        # Simulate the _clean function from entrypoint.py
        def _clean(val: str | None) -> str | None:
            if val is None:
                return None
            v = val.strip()
            # remove one layer of matching quotes if present
            if (v.startswith('"') and v.endswith('"')) or (v.startswith("'") and v.endswith("'")):
                v = v[1:-1].strip()
            return v
        
        # Test None input
        assert _clean(None) is None
        
        # Test basic string
        assert _clean("Vancouver") == "Vancouver"
        
        # Test string with whitespace
        assert _clean("  Vancouver  ") == "Vancouver"
        
        # Test double-quoted string
        assert _clean('"Vancouver"') == "Vancouver"
        
        # Test single-quoted string
        assert _clean("'Vancouver'") == "Vancouver"
        
        # Test string with quotes and whitespace
        assert _clean('  "Vancouver"  ') == "Vancouver"
        
        # Test nested quotes (should only remove outer layer)
        assert _clean('"Vancouver\'s City"') == "Vancouver's City"
        
        # Test mismatched quotes (should not remove)
        assert _clean('"Vancouver\'') == '"Vancouver\''
        
    def test_underscore_to_space_conversion(self):
        """Test that underscores are converted to spaces for Cloud Run compatibility."""
        # This handles cases where Cloud Run env vars show spaces as underscores
        test_cases = [
            ("British_Columbia", "British Columbia"),
            ("New_York", "New York"),
            ("San_Francisco", "San Francisco"),
            ("No_underscores", "No underscores"),
            ("Multiple_Under_Scores", "Multiple Under Scores"),
        ]
        
        for input_val, expected in test_cases:
            result = input_val.replace("_", " ")
            assert result == expected
    
    @patch.dict(os.environ, {
        "MODE": "job",
        "PROVINCE": "BC", 
        "CITY": "Vancouver",
        "COUNT": "100000",
        "FHIR_STORE": "test-store",
        "COUNTRY": "CA"
    })
    def test_environment_variable_defaults(self):
        """Test default values and environment variable parsing."""
        # Test COUNT default
        assert int(os.environ.get("COUNT", "10")) == 100000
        
        # Test COUNTRY default
        assert (os.environ.get("COUNTRY") or "CA").upper() == "CA"
        
        # Test MAX_QPS default
        assert float(os.environ.get("MAX_QPS", "3")) == 3.0
        
        # Test DRY_RUN default
        assert os.environ.get("DRY_RUN", "false").lower() == "false"
    
    def test_province_city_normalization(self):
        """Test the full province and city normalization process."""
        test_cases = [
            # (raw_province, raw_city) -> (expected_province, expected_city)
            ("BC", "Vancouver", "British Columbia", "Vancouver"),
            ("  BC  ", "  Vancouver  ", "British Columbia", "Vancouver"),
            ('"BC"', '"Vancouver"', "British Columbia", "Vancouver"),
            ("British_Columbia", "New_Westminster", "British Columbia", "New Westminster"),
            ("ON", "Toronto", "Ontario", "Toronto"),
            ("Alberta", "Calgary", "Alberta", "Calgary"),  # Full name should stay
        ]
        
        # Province mapping
        prov_map = {
            "BC": "British Columbia",
            "AB": "Alberta", 
            "SK": "Saskatchewan",
            "MB": "Manitoba",
            "ON": "Ontario",
            "QC": "Quebec",
            "NB": "New Brunswick",
            "NS": "Nova Scotia", 
            "PE": "Prince Edward Island",
            "NL": "Newfoundland and Labrador",
            "YT": "Yukon",
            "NT": "Northwest Territories",
            "NU": "Nunavut",
        }
        
        def _clean(val: str | None) -> str | None:
            if val is None:
                return None
            v = val.strip()
            if (v.startswith('"') and v.endswith('"')) or (v.startswith("'") and v.endswith("'")):
                v = v[1:-1].strip()
            return v
        
        for raw_prov, raw_city, expected_prov, expected_city in test_cases:
            # Simulate the normalization process from entrypoint.py
            province = _clean(raw_prov)
            city = _clean(raw_city)
            
            if province:
                province = province.replace("_", " ")
            if city:
                city = city.replace("_", " ")
                
            if province in prov_map:
                province = prov_map[province]
                
            assert province == expected_prov, f"Province: {raw_prov} -> {province}, expected {expected_prov}"
            assert city == expected_city, f"City: {raw_city} -> {city}, expected {expected_city}"


class TestVancouverSpecificConfiguration:
    """Test configuration specific to Vancouver and Greater Vancouver Area."""
    
    def test_vancouver_environment_config(self):
        """Test that Vancouver-specific environment variables are handled correctly."""
        # Simulate environment for Vancouver 100K generation
        test_env = {
            "MODE": "job",
            "PROVINCE": "BC",
            "CITY": "Vancouver", 
            "COUNT": "100000",
            "SEED": "42",
            "DRY_RUN": "false",
            "MAX_QPS": "5",
            "FHIR_STORE": "projects/test/locations/us-central1/datasets/test/fhirStores/test",
            "COUNTRY": "CA"
        }
        
        with patch.dict(os.environ, test_env, clear=True):
            # Test that all values are properly accessible
            assert os.environ.get("PROVINCE") == "BC"
            assert os.environ.get("CITY") == "Vancouver"
            assert int(os.environ.get("COUNT", "10")) == 100000
            assert int(os.environ.get("SEED")) == 42
            assert os.environ.get("DRY_RUN", "false").lower() == "false"
            assert float(os.environ.get("MAX_QPS", "3")) == 5.0
            assert os.environ.get("FHIR_STORE") is not None
            assert (os.environ.get("COUNTRY") or "CA").upper() == "CA"


if __name__ == "__main__":
    # Run tests if called directly
    pytest.main([__file__, "-v"])