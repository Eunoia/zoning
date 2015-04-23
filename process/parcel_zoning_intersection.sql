/*SET UP PARCELS, 
SELECT VALID GEOMS ONLY, 
PUT THEM IN EPSG USED FOR ZONING*/

ALTER TABLE parcel 
   ALTER COLUMN geom 
   TYPE Geometry(MultiPolygon, 26910) 
   USING ST_Transform(geom, 26910);

CREATE TABLE parcel_invalid AS
SELECT *
FROM parcel
WHERE ST_IsValid(geom) = false;

CREATE TABLE parcel_geometrycollection
AS
SELECT *
FROM parcel
WHERE GeometryType(geom) = 'GEOMETRYCOLLECTION';
--returns 0 rows

DELETE FROM parcel
WHERE GeometryType(geom) = 'GEOMETRYCOLLECTION';

--WHY ISN'T THE FOLLOWING NECESSARY/USED LATER?
CREATE TABLE parcel_valid as 
SELECT * FROM parcel
WHERE ST_IsValid(geom) = true;

/*SET UP ZONING, 
SELECT VALID GEOMS ONLY*/

CREATE TABLE zoning.lookup_valid AS
SELECT 
	ogc_fid, tablename, ST_MakeValid(the_geom) geom
FROM
	zoning.merged_jurisdictions;

CREATE INDEX lookup_2012_valid_gidx ON zoning.lookup_valid USING GIST (geom);

CREATE TABLE zoning.parcel_intersection_count AS
SELECT geom_id, count(*) as countof FROM
			zoning.lookup_valid as z, parcel p
			WHERE ST_Intersects(z.geom, p.geom)
			GROUP BY geom_id;

DROP TABLE IF EXISTS zoning.parcels_with_multiple_zoning;
CREATE TABLE zoning.parcels_with_multiple_zoning AS
SELECT * from parcel where geom_id
IN (SELECT geom_id FROM zoning.parcel_intersection_count WHERE countof>1);
--Query returned successfully: 462655 rows affected, 6854 ms execution time.

CREATE INDEX z_parcels_with_multiple_zoning_gidx ON zoning.parcels_with_multiple_zoning USING GIST (geom);
VACUUM (ANALYZE) zoning.parcels_with_multiple_zoning;

DROP TABLE IF EXISTS zoning.parcels_with_one_zone;
CREATE TABLE zoning.parcels_with_one_zone AS
SELECT * from parcel where geom_id
IN (SELECT geom_id FROM zoning.parcel_intersection_count WHERE countof=1);
--Query returned successfully: 1311776 rows affected, 16436 ms execution time.

CREATE INDEX z_parcels_with_one_zone_gidx ON zoning.parcels_with_one_zone USING GIST (geom);
VACUUM (ANALYZE) zoning.parcels_with_one_zone;

CREATE TABLE zoning.parcel AS
select p.geom_id, z.id, 100 as prop
from zoning.parcels_with_one_zone p,
zoning.lookup_valid z
WHERE ST_Intersects(z.the_geom, p.geom);
--Query returned successfully: 1263160 rows affected, 1140264 ms execution time.

/*BELOW DEAL WITH THE PARCELS 
WHICH INTERSECT WITH MORE 
THAN 1 ZONING MULTIPOLYGON
*/

--First, get stats on how much area falls in each intersection
--IF THERE ARE PROBLEMS WITH THIS overlap selection
--take a look at the history for this script for one that
--uses fewer columns from the zoning.lookup_valid table
CREATE TABLE zoning.parcel_overlaps AS
SELECT 
	parcel_id,
	ogc_fid,
	tablename,
	sum(ST_Area(geom)) area,
	round(sum(ST_Area(geom))/min(parcelarea) * 1000) / 10 prop,
	ST_Union(geom) geom
FROM (
SELECT p.parcel_id, 
	z.ogc_fid, 
	z.tablename,
 	ST_Area(p.geom) parcelarea, 
 	ST_Intersection(p.geom, z.geom) geom
FROM zoning.parcels_with_multiple_zoning p,
zoning.lookup_valid as z
WHERE ST_Intersects(z.geom, p.geom)
) f
GROUP BY 
	parcel_id,
	ogc_fid,
	tablename;

ALTER TABLE zoning.parcel_overlaps ADD COLUMN id INTEGER;
CREATE SEQUENCE zoning_parcel_overlaps_id_seq;
UPDATE zoning.parcel_overlaps  SET id = nextval('zoning_parcel_overlaps_id_seq');
ALTER TABLE zoning.parcel_overlaps ALTER COLUMN id SET DEFAULT nextval('zoning_parcel_overlaps_id_seq');
ALTER TABLE zoning.parcel_overlaps ALTER COLUMN id SET NOT NULL;
ALTER TABLE zoning.parcel_overlaps ADD PRIMARY KEY (id);

-- PRINT OUT A SUMMARY OF THE RESULTS OF PARCEL overlaps:

select width_bucket(prop, 0, 100, 9), count(*)
    from zoning.parcel_overlaps
group by 1
order by 1;

--select only those pairs of geom_id, zoning_id in which
--the proportion of overlap is the maximum
DROP TABLE IF EXISTS zoning.parcel_overlaps_maxonly;
CREATE TABLE zoning.parcel_overlaps_maxonly AS
SELECT geom_id, id, prop 
FROM zoning.parcel_overlaps WHERE (geom_id,prop) IN 
( SELECT geom_id, MAX(prop)
  FROM zoning.parcel_overlaps
  GROUP BY geom_id
);
--Query returned successfully: 535672 rows affected, 2268 ms execution time.
--Unfortunately, many parcels have 2 max values

--So, create table of parcels with >1 max values
DROP TABLE IF EXISTS zoning.parcel_two_max;
CREATE TABLE zoning.parcel_two_max AS
SELECT geom_id, id, prop FROM 
zoning.parcel_overlaps_maxonly where (geom_id) IN
	(
	SELECT geom_id from 
	(
	select geom_id, count(*) as countof from 
	zoning.parcel_overlaps_maxonly
	GROUP BY geom_id
	) b
	WHERE b.countof>1
	);
--Query returned successfully: 145309 rows affected, 817 ms execution time.

--same for 1 max, except insert those into the parcel table
INSERT INTO zoning.parcel
SELECT geom_id, id, prop FROM 
zoning.parcel_overlaps_maxonly where (geom_id) IN
	(
	SELECT geom_id from 
	(
	select geom_id, count(*) as countof from 
	zoning.parcel_overlaps_maxonly
	GROUP BY geom_id
	) b
	WHERE b.countof=1
	);
--Query returned successfully: 390363 rows affected, 1634 ms execution time.

/*
BELOW WE DEAL WITH THE PARCELS 
THAT ARE CLAIMED BY 2 (OR MORE) 
JURISDICTIONAL ZONING GEOMETRIES 
*/

CREATE TABLE zoning.parcel_counties AS
SELECT p.*, county.name10 as countyname1, county.namelsad10 as countyname2, county.geoid10 countygeoid FROM
			administrative.boundaries_counties county,
			parcel p
			WHERE ST_Intersects(county.geom, p.geom);
--Query returned successfully: 1954393 rows affected, 142212 ms execution time.

CREATE TABLE zoning.parcel_cities_counties AS
SELECT p.*, city.name10 as cityname1, city.namelsad10 as cityname2, city.geoid10 citygeoid FROM
			administrative.boundaries_cities city,
			zoning.parcel_counties p 
			WHERE ST_Intersects(city.geom, p.geom);
--Query returned successfully: 1691011 rows affected, 121759 ms execution time.

CREATE TABLE zoning.parcel_in_cities AS
SELECT p2n.geom_id, p2n.id 
FROM 
zoning.parcel_cities_counties pcc,
(SELECT c.city, p2.geom_id, p2.id 
FROM
zoning.codes_base2012 c,
zoning.parcel_two_max p2
WHERE c.id = p2.id) p2n
WHERE p2n.geom_id = pcc.geom_id
AND pcc.cityname1 = p2n.city;
--Query returned successfully: 48928 rows affected, 3750 ms execution time.

CREATE TABLE zoning.parcel_in_cities_doubles AS 
SELECT geom_id
FROM
(SELECT geom_id, count(*) AS countof
FROM zoning.parcel_in_cities
GROUP BY geom_id) p
WHERE p.countof>1;

DELETE FROM zoning.parcel_in_cities WHERE geom_id IN
(
SELECT geom_id
FROM
(SELECT geom_id, count(*) AS countof
FROM zoning.parcel_in_cities
GROUP BY geom_id) p
WHERE p.countof>1);
--Query returned successfully: 3121 rows affected, 87 ms execution time.

create INDEX zoning_parcel_in_cities_geomid_idx ON zoning.parcel_in_cities using hash (geom_id);

INSERT INTO zoning.parcel
SELECT z.geom_id, z.id, zo.prop
FROM
zoning.parcel_overlaps_maxonly zo,
zoning.parcel_in_cities z
WHERE z.geom_id = zo.geom_id
AND zo.id = z.id;
--Query returned successfully: 45807 rows affected, 1129 ms execution time.

--select parcels that have multiple overlaps that are not in cities
DROP VIEW IF EXISTS zoning.parcel_two_max_not_in_cities;
CREATE TABLE zoning.parcel_two_max_not_in_cities AS
SELECT * from zoning.parcel_two_max_geo WHERE geom_id 
NOT IN (
SELECT geom_id 
FROM
zoning.parcel_in_cities);

CREATE INDEX zoning_parcel_two_max_not_in_cities_gidx ON zoning.parcel_two_max_not_in_cities USING GIST (geom);

DROP TABLE IF EXISTS zoning.parcel_in_counties;
CREATE TABLE zoning.parcel_in_counties AS
SELECT p2n.geom_id, p2n.zoning_id, p2n.city, cb.name10 as countyname1, p2n.geom 
FROM 
	(SELECT c.city, p2.geom_id, p2.zoning_id, p2.geom
	FROM
	zoning.codes_base2012 c,
	zoning.parcel_two_max_not_in_cities p2
	WHERE c.id = p2.zoning_id) p2n,
	administrative.boundaries_counties cb
WHERE ST_Intersects(cb.geom,p2n.geom);
--Query returned successfully: 50561 rows affected, 2052 ms execution time.

DROP TABLE IF EXISTS zoning.temp_parcel_county_table;
CREATE TABLE zoning.temp_parcel_county_table AS
SELECT * from 
zoning.parcel_in_counties p
WHERE 
regexp_replace(city, 'Unincorporated ','') = countyname1;
--Total query runtime: 2414 ms. -- 25403 rows retrieved.

create INDEX zoning_temp_parcel_county_table_geomid_idx ON zoning.temp_parcel_county_table using hash (geom_id);

/*
COPY PARCELS WITHIN MULTIPLE CITIES 
AND PARCELS WITHIN MULTIPLE COUNTIES 
TO A SEPARATE TABLE, AND THEN REMOVE 
THEM FROM THE PARCEL/ZONING MAPPING
BECAUSE WE CANNOT ASSIGN THEM 
ONLY 1 ZONING TYPE USING THE RULE 
BASED ON WHICH JURISDICTION THEY ARE LOCATED IN
*/

CREATE TABLE zoning.parcels_in_multiple_cities AS
SELECT * FROM zoning.parcel_in_cities WHERE geom_id IN
(
SELECT geom_id
FROM
(SELECT geom_id, count(*) AS countof
FROM zoning.parcel_in_cities
GROUP BY geom_id) p
WHERE p.countof>1);
--Query returned successfully: 3121 rows affected, 3337 ms execution time.

CREATE TABLE zoning.parcels_in_multiple_counties AS
SELECT * FROM zoning.temp_parcel_county_table WHERE geom_id IN
(
SELECT geom_id
FROM
(SELECT geom_id, count(*) AS countof
FROM zoning.temp_parcel_county_table
GROUP BY geom_id) p
WHERE p.countof>1);

\COPY zoning.parcels_in_multiple_cities TO '/zoning_data/parcels_in_multiple_cities.csv' DELIMITER ',' CSV HEADER;
https://mtcdrive.box.com/shared/static/uumadei43eqxl5ll90fdtqz7nxhhg711.csv;

\COPY zoning.parcels_in_multiple_counties TO '/zoning_data/parcels_in_multiple_counties.csv' DELIMITER ',' CSV HEADER;
https://mtcdrive.box.com/shared/static/ouya6lylpd4e1z5vqfz2gngebkmgfkur.csv;

DELETE FROM zoning.temp_parcel_county_table WHERE geom_id IN
(
SELECT geom_id
FROM
(SELECT geom_id, count(*) AS countof
FROM zoning.temp_parcel_county_table
GROUP BY geom_id) p
WHERE p.countof>1);
--Query returned successfully: 712 rows affected, 65 ms execution time.

-------------------------------------------
-------------------------------------------
-------------------------------------------
-------------------------------------------
-------------------------------------------
-------------------------------------------

INSERT INTO zoning.parcel
SELECT z.geom_id, z.zoning_id, zo.prop
FROM
zoning.parcel_overlaps_maxonly zo,
zoning.temp_parcel_county_table z
WHERE z.geom_id = zo.geom_id
AND zo.id = z.zoning_id;
--Query returned successfully: 24691 rows affected, 560 ms execution time.

--THE FOLLOWING IS A CHECK THAT PARCELS ARE STILL UNIQUE
SELECT COUNT(geom_id) - COUNT(DISTINCT geom_id) FROM zoning.parcel;
--0

-------------------------------------------------
-------------------------------------------------
-------------------------------------------------
----------OUTPUT RESULTING TABLE TO CSV----------
-------------------------------------------------
-------------------------------------------------
-------------------------------------------------

COPY zoning.parcel TO '/zoning_data/zoning_parcels03_30_2015.csv' DELIMITER ',' CSV HEADER;


/*
BELOW WE CREATE TABLES WITH GEOGRAPHIC DATA
FOR VISUAL INSPECTION OF OF THE ABOVE
*/

--create geographic table of double max parcels for visual inspection
CREATE TABLE zoning.parcel_two_max_geo AS
SELECT zr.*,p.geom,p.geom_id,two.prop FROM 
zoning.parcel_two_max two,
parcel p,
zoning.regional zr
WHERE two.geom_id = p.geom_id
AND zr.id = two.id;

CREATE INDEX zoning_parcel_overlaps_geom_idx ON zoning.parcel_overlaps USING hash (geom_id);
CREATE INDEX zoning_parcel_two_max_geom_idx ON zoning.parcel_two_max USING hash (geom_id);
CREATE INDEX zoning_parcel_overlaps_idx ON zoning.parcel_overlaps USING hash (id);
CREATE INDEX zoning_parcel_two_max_idx ON zoning.parcel_two_max USING hash (id);

--create same from overlaps union table
CREATE TABLE zoning.parcel_two_max_geo_overlaps AS
SELECT pzo.*
FROM 
zoning.parcel_two_max two,
zoning.parcel_overlaps pzo
WHERE two.geom_id = pzo.geom_id
AND two.id = pzo.id;

--create indexes for the query below
create INDEX zoning_parcel_lookup_geom_idx ON zoning.parcel using hash (geom_id);
create INDEX parcel_geom_id_idx ON parcel using hash (geom_id);

--output a table with geographic information and generic code info for review
CREATE TABLE zoning.parcel_withdetails AS
SELECT p.geom, z.*
FROM zoning.parcel pz,
zoning.codes_base2012 z,
parcel p
WHERE pz.id = z.id AND p.geom_id = pz.geom_id;

create INDEX zoning_parcel_two_max_lookup_geom_idx ON zoning.parcel_two_max using hash (geom_id);
create INDEX zoning_regional_id ON zoning.regional using hash (id);

CREATE TABLE zoning.parcel_two_max_geo AS
SELECT p.geom,p.geom_id, two.id as zoning_id, two.prop FROM 
zoning.parcel_two_max two,
parcel p
WHERE two.geom_id = p.geom_id;

create INDEX parcel_geom_id_idx ON parcel using hash (geom_id);

--USE PLU 2008 WHERE NO OTHER DATA AVAILABLE

CREATE TABLE zoning.unmapped_parcels AS
select * from parcel 
where geom_id not in (
SELECT geom_id from zoning.parcel);

CREATE TABLE zoning.unmapped_parcel_zoning AS
SELECT p.geom_id, z.origgplu,z.gengplu 
FROM zoning.unmapped_parcels p,
public.plu2008_updated z 
WHERE ST_Intersects(z.geom,p.geom);

CREATE TABLE zoning.unmapped_parcel_intersection_count AS
SELECT geom_id, count(*) as countof FROM
			public.plu2008_updated as z, zoning.unmapped_parcels p
			WHERE ST_Intersects(z.geom, p.geom)
			GROUP BY geom_id;


DROP TABLE IF EXISTS zoning.parcels_with_multiple_zoning;
CREATE TABLE zoning.parcels_with_multiple_zoning AS
SELECT * from parcel where geom_id
IN (SELECT geom_id FROM zoning.parcel_intersection_count WHERE countof>1);
--Query returned successfully: 462655 rows affected, 6854 ms execution time.

CREATE INDEX z_parcels_with_multiple_zoning_gidx ON zoning.parcels_with_multiple_zoning USING GIST (geom);
VACUUM (ANALYZE) zoning.parcels_with_multiple_zoning;

DROP TABLE IF EXISTS zoning.parcels_with_one_zone;
CREATE TABLE zoning.parcels_with_one_zone AS
SELECT * from parcel where geom_id
IN (SELECT geom_id FROM zoning.parcel_intersection_count WHERE countof=1);
--Query returned successfully: 1311776 rows affected, 16436 ms execution time.

CREATE INDEX z_parcels_with_one_zone_gidx ON zoning.parcels_with_one_zone USING GIST (geom);
VACUUM (ANALYZE) zoning.parcels_with_one_zone;
