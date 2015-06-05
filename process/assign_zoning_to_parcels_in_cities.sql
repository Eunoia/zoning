CREATE TABLE zoning.parcel_in_cities AS
SELECT p2n.geom_id, p2n.zoning_id 
FROM 
zoning.parcel_cities_counties pcc,
(SELECT c.city, p2.geom_id, p2.zoning_id 
FROM
zoning.codes_dictionary c,
zoning.parcel_two_max p2 --parcel_two_max is a twice derived view on zoning.parcel_overlaps
WHERE c.id = p2.zoning_id) p2n
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

CREATE INDEX zoning_parcel_two_max_zoningid_idx ON zoning.parcel_two_max USING hash (zoning_id);
CREATE INDEX zoning_parcel_two_max_geomid_idx ON zoning.parcel_two_max USING hash (geom_id);
VACUUM (ANALYZE) zoning.parcel_two_max;

CREATE TABLE zoning.parcel_two_max_geo AS
SELECT two.zoning_id,p.geom_id,two.prop,p.geom 
FROM 
	(select zoning_id, geom_id, prop from zoning.parcel_two_max) as two,
	(select geom_id, geom from parcel) as p
WHERE two.geom_id = p.geom_id;

create INDEX zoning_parcel_in_cities_geomid_idx ON zoning.parcel_in_cities using hash (geom_id);
VACUUM (ANALYZE) zoning.parcel_in_cities;

--select parcels that have multiple overlaps that are not in cities
DROP VIEW IF EXISTS zoning.parcel_two_max_not_in_cities;
CREATE TABLE zoning.parcel_two_max_not_in_cities AS
SELECT * from zoning.parcel_two_max_geo WHERE geom_id 
NOT IN (
SELECT geom_id 
FROM
zoning.parcel_in_cities);

CREATE INDEX zoning_parcel_two_max_not_in_cities_gidx ON zoning.parcel_two_max_not_in_cities USING GIST (geom);
