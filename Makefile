# if using the postgres/postgis development vm, https://github.com/buckleytom/pg-app-dev-vm, 
# the user will need to create a file called ~/.pgpass with the following line:
# localhost:25432:vagrant:vagrant:vagrant
#need to add
# parcels_zoning_santa_clara.sql
# parcels_fairfield.sql: 

#the following are just stubs and won't work right now
parcel_zoning.csv: bay_area_zoning.sql \
	parcels_spandex.sql \
	source_field_name.sql \
	plu_bay_area_zoning.sql \
	parcels_zoning_update9.sql \
	ba8_parcels.sql 
	psql -p 25432 -h localhost -U vagrant vagrant process/update9places.sql
	psql -p 25432 -h localhost -U vagrant vagrant process/parcel_zoning_intersection.sql

bay_area_zoning.sql: data_source/PlannedLandUsePhase1.gdb \
	data_source/zoning_codes_base2012.csv \
	data_source/match_fields_tables_zoning_2012_source.csv
	psql -p 25432 -h localhost -U vagrant -c "CREATE SCHEMA zoning;"
	bash load/load-2012-zoning.sh
	psql -p 25432 -h localhost -U vagrant vagrant -f process/load-generic-zoning-code-table.sql
	psql -p 25432 -h localhost -U vagrant vagrant -f process/merge_jurisdiction_zoning.sql

data_source/PlannedLandUsePhase1.gdb: data_source/PlannedLandUse1Through6.gdb.zip
	unzip -d data_source/ data_source/PlannedLandUse1Through6.gdb.zip

data_source/PlannedLandUse1Through6.gdb.zip: s3-curl/s3curl.pl
	perl s3-curl/s3curl.pl --id=company 
	-- http://landuse.s3.amazonaws.com/zoning/PlannedLandUse1Through6.gdb.zip \
	-o data_source/PlannedLandUse1Through6.gdb.zip

data_source/match_fields_tables_zoning_2012_source.csv:
	perl s3-curl/s3curl.pl --id=company \
	-- http://landuse.s3.amazonaws.com/zoning/match_fields_tables_zoning_2012_source.csv \
	-o data_source/match_fields_tables_zoning_2012_source.csv

data_source/zoning_codes_base2012.csv:
	perl s3-curl/s3curl.pl --id=company \
	-- http://landuse.s3.amazonaws.com/zoning/zoning_codes_base2012.csv \
	-o data_source/zoning_codes_base2012.csv

#where plu refers to the old "planned land use"/comprehensive plan project
plu_bay_area_zoning.sql: data_source/PLU2008_Updated.shp
	ogr2ogr -f "PostgreSQL" \ 
	PG:"host=localhost port=25432 dbname=vagrant user=vagrant password=vagrant" \
	data_source/PLU2008_Updated.shp
	pg_dump vagrant --table=plu2008_updated > plu_bay_area_zoning.sql

data_source/PLU2008_Updated.shp: 
	perl s3-curl/s3curl.pl --id=company \
	-- http://landuse.s3.amazonaws.com/zoning/PLU2008_Updated.zip \
	-o data_source/PLU2008_Updated.zip
	unzip data_source/PLU2008_Updated
	touch data_source/PLU2008_Updated.shp 

# data_source/jurisdiction_zoning.sql:
# 	perl s3-curl/s3curl.pl --id=company \
# 	-- http://landuse.s3.amazonaws.com/zoning/jurisdiction_zoning.sql \
# 	-o data_source/jurisdiction_zoning.sql

parcels_spandex.sql:
	perl s3-curl/s3curl.pl --id=company \
	-- http://landuse.s3.amazonaws.com/zoning/parcels_spandex.sql \
	-o data_source/parcels_spandex.sql

update9_parcels.sql: data_source/Parcels2010_Update9.csv
	psql vagrant -p 25432 -U vagrant -h localhost -f load/update9.sql

data_source/ba8_parcels.sql: 
	perl s3-curl/s3curl.pl --id=company \
	-- http://landuse.s3.amazonaws.com/zoning/ba8_parcels.sql \
	-o data_source/ba8_parcels.sql

data_source/zoning_data/zoning_codes_dictionary.csv: s3-curl/s3curl.pl
	perl s3-curl/s3curl.pl --id=company \
	-- http://landuse.s3.amazonaws.com/zoning/zoning_data/zoning_codes_dictionary.csv \
	-o data_source/zoning_codes_dictionary.csv 

s3curl/s3curl.pl: s3curl.zip
	unzip s3-curl.zip

s3curl.zip:
	curl -o s3-curl.zip http://s3.amazonaws.com/doc/s3-example-code/s3-curl.zip

# since FileGDB requires gdal 1.11 and ubuntu trusty gdal is 1.10,
# just loading these from sql dumps for now.
# can fix this when GDAL 1.11/2.0 gets released
#
