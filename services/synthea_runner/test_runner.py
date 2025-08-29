#!/usr/bin/env python3
"""
Unit tests for Synthea Runner - validates geographic handling and configuration.
"""

import pytest
import os
import tempfile
from pathlib import Path
from unittest.mock import patch, MagicMock

from runner import RunConfig, ensure_assets


class TestRunConfig:
    """Test RunConfig initialization and validation."""
    
    def test_basic_config(self):
        """Test basic RunConfig creation."""
        cfg = RunConfig(
            province="British Columbia",
            city="Vancouver", 
            count=10,
            seed=12345,
            dry_run=True,
            max_qps=1.0,
            fhir_store="test-store",
            country="CA"
        )
        
        assert cfg.province == "British Columbia"
        assert cfg.city == "Vancouver"
        assert cfg.count == 10
        assert cfg.seed == 12345
        assert cfg.dry_run is True
        assert cfg.max_qps == 1.0
        assert cfg.fhir_store == "test-store"
        assert cfg.country == "CA"
    
    def test_config_with_none_values(self):
        """Test RunConfig with None values for optional fields."""
        cfg = RunConfig(
            province=None,
            city=None,
            count=100,
            seed=None,
            dry_run=False,
            max_qps=3.0,
            fhir_store="test-store",
            country="CA"
        )
        
        assert cfg.province is None
        assert cfg.city is None
        assert cfg.seed is None
        
    def test_fhir_store_path_normalization(self):
        """Test that FHIR store paths are normalized correctly."""
        cfg = RunConfig(
            province="British Columbia",
            city="Vancouver",
            count=10,
            seed=None,
            dry_run=True,
            max_qps=1.0,
            fhir_store="test-store/",  # trailing slash should be removed
            country="CA"
        )
        
        assert cfg.fhir_store == "test-store"
        
    def test_country_code_normalization(self):
        """Test that country codes are normalized to uppercase."""
        cfg = RunConfig(
            province="British Columbia",
            city="Vancouver",
            count=10,
            seed=None,
            dry_run=True,
            max_qps=1.0,
            fhir_store="test-store",
            country="ca"  # lowercase should become uppercase
        )
        
        assert cfg.country == "CA"


class TestGeographicHandling:
    """Test geographic validation and handling for Canadian locations."""
    
    @pytest.mark.parametrize("province,city,expected_valid", [
        ("British Columbia", "Vancouver", True),
        ("British Columbia", "Burnaby", True),
        ("British Columbia", "Surrey", True),
        ("British Columbia", "Richmond", True),
        ("British Columbia", None, True),  # Province-only should work
        ("Ontario", "Toronto", True),
        ("Quebec", "Montreal", True),
        (None, None, True),  # Should work for country-wide generation
        ("British Columbia", "NonexistentCity", True),  # Should fallback to province-only
    ])
    def test_geographic_combinations(self, province, city, expected_valid):
        """Test various province/city combinations for Canadian geography."""
        try:
            cfg = RunConfig(
                province=province,
                city=city,
                count=10,
                seed=12345,
                dry_run=True,
                max_qps=1.0,
                fhir_store="test-store",
                country="CA"
            )
            # If we get here without exception, creation succeeded
            assert expected_valid
        except Exception as e:
            assert not expected_valid, f"Unexpected error for {province}/{city}: {e}"


class TestCountrySupport:
    """Test country code validation and support."""
    
    def test_supported_countries(self):
        """Test that supported countries work."""
        for country in ["CA", "US"]:
            cfg = RunConfig(
                province="British Columbia" if country == "CA" else "Massachusetts",
                city="Vancouver" if country == "CA" else "Boston",
                count=10,
                seed=12345,
                dry_run=True,
                max_qps=1.0,
                fhir_store="test-store",
                country=country
            )
            assert cfg.country == country
    
    def test_unsupported_country_in_ensure_assets(self):
        """Test that unsupported countries raise errors in ensure_assets."""
        with pytest.raises(ValueError, match="Unsupported COUNTRY.*Only 'CA' and 'US' are supported"):
            ensure_assets("UK")


class TestVancouverSpecificCases:
    """Test Vancouver and Greater Vancouver Area specific scenarios."""
    
    def test_vancouver_config(self):
        """Test configuration specifically for Vancouver."""
        cfg = RunConfig(
            province="British Columbia",
            city="Vancouver",
            count=100000,  # 100K patients as requested
            seed=12345,
            dry_run=True,
            max_qps=5.0,
            fhir_store="projects/test/locations/us-central1/datasets/test/fhirStores/test",
            country="CA"
        )
        
        assert cfg.province == "British Columbia"
        assert cfg.city == "Vancouver"
        assert cfg.count == 100000
        
    def test_greater_vancouver_cities(self):
        """Test major Greater Vancouver Area cities."""
        gva_cities = ["Vancouver", "Burnaby", "Surrey", "Richmond", "Coquitlam", "Langley"]
        
        for city in gva_cities:
            cfg = RunConfig(
                province="British Columbia",
                city=city,
                count=10000,
                seed=12345,
                dry_run=True,
                max_qps=3.0,
                fhir_store="test-store",
                country="CA"
            )
            
            assert cfg.city == city
            assert cfg.province == "British Columbia"


if __name__ == "__main__":
    # Run tests if called directly
    pytest.main([__file__, "-v"])