DROP TABLE IF EXISTS zoning_staging.shapefile_metadata;
CREATE TABLE zoning_staging.shapefile_metadata (    
    juris_id integer CONSTRAINT juris_id_pk PRIMARY KEY, --in source data called "juris"
    shapefile_name text,
    common_name text, 
    collection_project_year numeric(4,0), 
    regulation_type text, 
    year_in_tablename numeric(4,0),
    county boolean
);

\COPY zoning_staging.shapefile_metadata FROM 'zoning_source_metadata.csv' WITH (FORMAT csv, DELIMITER ',', HEADER FALSE);