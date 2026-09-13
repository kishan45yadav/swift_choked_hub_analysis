CREATE TABLE raw_shipments (
    doc jsonb
);

-- Load Data

COPY raw_shipments
FROM 'C:\Users\Public\SWIFT Assignment 7 - Analyst - CH - Copy.json'
WITH (FORMAT csv, QUOTE E'\x01', DELIMITER E'\x02');

select * from raw_shipments 
limit 10 ;

-- Extract Field

CREATE TABLE shipments AS
SELECT
    doc->>'shipment_id'      AS shipment_id,
    doc->>'latest_status'    AS latest_status,
    doc->>'latest_location'  AS latest_location,
    doc->'deduped_track_details' AS track_details
FROM raw_shipments;

-- deduped_track_details(unnest)

CREATE TABLE shipment_stops AS
SELECT
    s.shipment_id,
    s.latest_status,
    (elem->>'location') AS location,
    (elem->>'ctime')::timestamp AS ctime
FROM shipments s,
     jsonb_array_elements(s.track_details) AS elem;

SELECT doc->'deduped_track_details' FROM raw_shipments LIMIT 1;

-- Missing Value check

SELECT count(*) FROM shipment_stops WHERE location IS NULL OR ctime IS NULL;
SELECT count(*) FROM shipments WHERE shipment_id IS NULL;

--Calculating Dwell time

CREATE TABLE stop_durations AS
SELECT
    shipment_id,
    location,
    ctime AS entry_time,
    LEAD(ctime) OVER (PARTITION BY shipment_id ORDER BY ctime) AS next_scan_time,
    latest_status
FROM shipment_stops;

ALTER TABLE stop_durations ADD COLUMN dwell_hours numeric;

UPDATE stop_durations
SET dwell_hours = EXTRACT(EPOCH FROM (
    COALESCE(next_scan_time, '2023-10-07'::timestamp) - entry_time
)) / 3600;

SELECT
    percentile_cont(0.5) WITHIN GROUP (ORDER BY dwell_hours) AS median_dwell,
    percentile_cont(0.75) WITHIN GROUP (ORDER BY dwell_hours) AS p75_dwell,
    percentile_cont(0.90) WITHIN GROUP (ORDER BY dwell_hours) AS p90_dwell
FROM stop_durations;

-- Warehouse_summary

CREATE TABLE warehouse_summary AS
SELECT
    location,
    count(*) AS total_stops,
    round(avg(dwell_hours), 1) AS avg_dwell_hours,
    percentile_cont(0.5) WITHIN GROUP (ORDER BY dwell_hours) AS median_dwell_hours,
    round(100.0 * sum(CASE WHEN dwell_hours > 24.72 THEN 1 ELSE 0 END) / count(*), 1) AS pct_delayed,
    sum(CASE WHEN next_scan_time IS NULL AND latest_status != 'Delivered' THEN 1 ELSE 0 END) AS currently_stuck,
    CASE
        WHEN count(*) >= 5
             AND (avg(dwell_hours) > 24.72
                  OR sum(CASE WHEN next_scan_time IS NULL AND latest_status != 'Delivered' THEN 1 ELSE 0 END) > 0)
        THEN 'Prioritize for Clearing'
        ELSE 'Ignore'
    END AS category
FROM stop_durations
GROUP BY location
ORDER BY avg_dwell_hours DESC;


SELECT category, count(*) FROM warehouse_summary GROUP BY category;

SELECT * FROM warehouse_summary WHERE category = 'Prioritize for Clearing' ORDER BY avg_dwell_hours DESC LIMIT 20;


SELECT category, count(*) FROM warehouse_summary GROUP BY category;
	 