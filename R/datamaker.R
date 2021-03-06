#' Get block groups
#' 
#' @return spatial points sf object from Census Bureau population weighted centroids
get_bglatlong <- function(){
  bgcentroid <- read_csv("https://www2.census.gov/geo/docs/reference/cenpop2010/blkgrp/CenPop2010_Mean_BG49.txt")
    
  st_as_sf(bgcentroid, coords = c("LONGITUDE", "LATITUDE"), crs = 4326) %>%
    mutate(id = str_c(STATEFP, COUNTYFP, TRACTCE, BLKGRPCE)) %>%
    filter(COUNTYFP == "049") %>%
    # remove block groups in stupid places
    filter(!id %in% c(
      "490499801001", # Camp williams
      "490490109002", # spanish fork peak
      "490490109001" # provo canyon
    )) %>%
    select(id, POPULATION)
}

#' Get GTFS File for OpenTripPlanner
#' 
#' @param file to data file
#' @return Stores a GTFS file in the appropriate location
#' 
get_gtfs <- function(path){
  if(!dir.exists(dirname(path))) dir.create(dirname(path))
  if(!file.exists(path)){
    # originally from UTA: June 4 2021
    download.file("https://gtfsfeed.rideuta.com/gtfs.zip",
                  destfile = path)
  } else {
    message(path, " already available")
  }
  return(path) # to use file target, need to return path to data. 
}


#' Get OSM PBF file for OpenTripPlanner
#' 
#' @param file to data file
#' @return Stores and unzips a PBF file in the data folder
#' 
get_osmbpf <- function(path){
  
  # check if otp file is already there. 
  if(!file.exists(path)){
    
    # if not, download file from osm
    geofabrik_file <- "data/utah.osm.pbf"
    if(!file.exists(geofabrik_file)){
      # get the osm pbf file from geofabrik
      download.file("https://download.geofabrik.de/north-america/us/utah-220328.osm.pbf",
                    geofabrik_file)
    }
    
    # osmosis --read-pbf file=ohio.osm.pbf --bounding-polygon file=input.poly --tf accept-ways boundary=administrative --used-node --write-xml output.osm
    system2("/opt/homebrew/bin/osmosis", 
            args = c(
              str_c("--read-pbf file=", geofabrik_file, sep = ""),
              "--bounding-box top=41.5733 left=-112.2638 bottom=39.8913 right=-111.5250 completeWays=yes",
              "--tf accept-ways highway=*",
              "--used-node",
              str_c("--write-pbf file=", path, sep = "")
            ))
  } else {
    message(path, " already available")
  }
  
  
  return(path) # to use file target, need to return path to data. 
}


#' Get parks polygons data
#' 
#' @param file A geojson file with parks data
#' @param crs Projected CRS to use for data; 
#' @return An sf object with parks as polygons with attributes
#' 
#' @details This dataset is small enough that we can just keep thd ata directly in git
#' 
get_parks <- function(file, crs){
  st_read(file) %>%
    st_transform(crs)  %>%
    mutate(id = as.character(id),
           acres = as.numeric(st_area(.))/43560,
           yj_acres = yeo.johnson(acres, 0)) %>%
    rename(splashpad = splashpad.)
}

#' Get points along park polygons
#' 
#' @param park_polygons An sf data frame with polygons
#' @param density Rate at which to sample points along the boundary.  density
#'   should be in units of the  projection.
#'   
#' @return A sf dataframe with points along the boundary
#' 
#' @details The parks are big enough we want to get distances to each point along
#' the boundary, rather than just a centroid.
make_park_points <- function(park_polygons, density, crs){
  
  # turn polygon boundaries into linestrings
  suppressWarnings(
    park_boundaries <- park_polygons %>%
      ungroup() %>%
      select(id) %>%
      # simplify boundaries
      st_simplify(dTolerance = 100, preserveTopology = TRUE) %>%
      st_cast("MULTIPOLYGON") %>% 
      st_cast("POLYGON") %>% 
      st_cast("LINESTRING", group_or_split = TRUE)
  )
  
  # sample points along lines
  point_samples <- park_boundaries %>%
    st_line_sample(density = 1/500)
  
  # make a dataset of points
  suppressWarnings(
    park_points <- st_sf(id = park_boundaries$id, geometry = point_samples) %>%
      st_as_sf() %>%
      st_cast(to = "POINT")%>%
      group_by(id)%>%
      ungroup()
  )
  
}



#' Get Libraries Data
#' 
#' @param file Path to libraries geojson file
#' @param crs Projected CRS to use for data; 
#' @return sf data frame with 
#' 
get_libraries <- function(file, crs){
  st_read(file) %>%
    st_transform(crs) %>%
    filter(keep) %>%
    transmute(
      id = NAME, computers, wifi, study_help, fooddrink, printer,  
      classes = ifelse(is.na(classes), FALSE, classes), 
      genealogy = ifelse(is.na(genealogy), FALSE, genealogy), 
      nonres_fee = parse_number(nonres_fee),
      area =  yeo.johnson(area, 0)
    ) 
}

#' Get Groceries shape information
#' 
#' @param file Path to groceries geojson file
#' @param data Path to groceries survey data
#' @param crs Projected CRS to use for data; 
#' @return sf data frame with groceries data
#' 
get_groceries <- function(file, data, crs){
  # read shape information
  gj <- st_read(file) %>%
    st_transform(crs) %>%
    filter(st_is(., c("MULTIPOLYGON"))) %>%
    rename(id = SITE_NAME) %>%
    filter(!duplicated(id))
  
  # read survey data 
  gd <- read_spss("data/NEMS-S_UC2021_brief.sav") %>%
    transmute(
      id = STORE_ID,
      type = as_factor(STORE_T, levels = "labels"),
      type2 = STORE_T_3_TEXT,
      pharmacy = STORE_T2_3Rx_2 == 1,
      ethnic = STORE_T2_4ETH == 1,
      merch = STORE_T2_6GEN == 1,
      registers = REGISTERS,
      selfchecko = SELFCHECKOUT,
      total_registers = REGISTERS_TOT
    )
  
  inner_join(gj, gd, by = "id")
  
}


groceries_map <- function(groceries){
  
  pal <- colorFactor("Dark2", groceries$type)
  
  leaflet(groceries %>% st_centroid() %>% st_transform(4326)) %>%
    addProviderTiles(providers$Esri.WorldGrayCanvas) %>%
    addCircles(color = ~pal(type), label = ~as.character(id), radius = ~(total_registers* 10))

}



#' Function to get lat / long from sf data as matrix
#' 
#' @param sfc A simple features collection
#' @return A data frame with three columns, id, LATITUDE and LONGITUDE
#' 
#' @details If sfc is a polygon, will first calculate the centroid.
#' 
get_latlong <- function(sfc){
  
  suppressWarnings(
  tib <- sfc |>
    sf::st_centroid() |> # will always warn for constant geometry
    sf::st_transform(4326) |>
    dplyr::transmute(
      id = as.character(id),
      lat = sf::st_coordinates(geometry)[, 2],
      lon = sf::st_coordinates(geometry)[, 1],
    ) |>
    sf::st_set_geometry(NULL)
  )
  
  tib
}




#' Calculate multimodal travel times between bgcentroids and destinations
#' 
#' @param landuse Destination features
#' @param bgcentroid Population-weighted blockgroup centroid
#' @param graph path to r5 database
#' @param osmpbf  path to osm pbf file
#' @param gtfs path to gtfs zip file
#' @param landuselimit The maximum number of resources to sample. Default NULL means all included
#' @param bglimit The maximum number of block groups included in sample. deafult NULL means all included
#' @param shortcircuit The path to a file that if given will skip the path calculations.
#' 
#' @return A tibble with times between Block groups and resources by multiple modes
#' 
#' @details Parallelized, will use parallel::detectCores() - 1
#' 
calculate_times <- function(landuse, bgcentroid, gtfs, osmpbf, landuselimit = NULL, bglimit = NULL,
                            shortcircuit = NULL){
  
  # short-circuit times calculator if the paths are already computed.
  if(!is.null(shortcircuit) & file.exists(shortcircuit)){ 
    warning("Using previously calculated times in ", shortcircuit)
    return(read_rds(shortcircuit))
  }
  
  # start connection to r5
  if(!file.exists(osmpbf)) stop("OSM file not present.")
  if(!file.exists(gtfs)) stop("GTFS file not present.")
  setup_r5(dirname(osmpbf), verbose = FALSE)
  
  
  # get lat / long for the landuse and the centroids
  ll <- get_latlong(landuse)
  bg <- get_latlong(bgcentroid)
  
  # limit the number of cells for the time calculations (for debugging)
  if(!is.null(landuselimit)) ll <- ll |>  sample_n(landuselimit)
  if(!is.null(bglimit)) bg <- bg |>  sample_n(bglimit)
  
  # Get distance between each ll and each bg
  r5r_core <- setup_r5(dirname(osmpbf), verbose = FALSE)
  
  # routing inputs
  max_trip_duration <- 120 # in minutes
  departure_datetime <- as.POSIXct("26-04-2022 08:00:00",
                                   format = "%d-%m-%Y %H:%M:%S")
  time_window <- 60L # how many minutes are scanned
  percentiles <- 25L # assumes riders have some knowledge of transit schedules
  
  
  # get the car travel times
  car_tt <- travel_time_matrix(
    r5r_core,
    bg,
    ll,
    mode = "CAR",
    departure_datetime = departure_datetime,
    time_window = time_window,
    percentiles = percentiles,
    breakdown = FALSE, # don't need detail for car trips
    breakdown_stat = "min",
    max_trip_duration = max_trip_duration,
    verbose = FALSE,
    progress = TRUE
  ) |> 
    mutate(mode = "CAR")
  
  # get the walk times
  walk_tt <- travel_time_matrix(
    r5r_core,
    bg,
    ll,
    mode = "WALK",
    departure_datetime = departure_datetime,
    time_window = time_window,
    percentiles = percentiles,
    breakdown = FALSE,
    breakdown_stat = "min",
    max_walk_dist = 10000, # in meters
    max_trip_duration = max_trip_duration,
    walk_speed = 3.6, # meters per second
    verbose = FALSE,
    progress = TRUE
  ) |> 
    mutate(mode = "WALK")
  
  
  # get the transit times
  transit_tt <- travel_time_matrix(
    r5r_core,
    bg,
    ll,
    mode = "TRANSIT",
    mode_egress = "WALK",
    departure_datetime = departure_datetime,
    time_window = time_window,
    percentiles = percentiles,
    breakdown = TRUE,
    breakdown_stat = "mean",
    max_walk_dist = 1000, # in meters
    max_trip_duration = max_trip_duration,
    walk_speed = 3.6, # meters per second
    verbose = FALSE,
    progress = TRUE
  ) |> 
    mutate(mode = "TRANSIT")  %>%
    filter(n_rides > 0)
  
  
  alltimes <- bind_rows(
    transit_tt, 
    car_tt, 
    walk_tt,
  ) |> 
    transmute(
      blockgroup = fromId,
      resource = toId,
      mode = mode,
      duration = travel_time,
      transfers = n_rides,
      walktime = access_time + egress_time,
      waittime = wait_time,
      transittime = ride_time
    ) |> 
    # keep only the shortest itinerary by origin / destination / mode
    # this is necessary because the parks have multiple points.
    group_by(resource, blockgroup, mode) |> 
    arrange(duration, .by_group = TRUE) |> 
    slice(1) |> 
    as_tibble()
  
  stop_r5()
  alltimes
}


#' Calculate mode choice logsums
#' 
#' @param times A tibble returned from calculate_times
#' @param utilities A list of mode choice utilities
#' @param walkspeed Assumed walking speed in miles per hour
#' 
#' @return A tibble with the mode choice logsum for each resource / blockgroup
#'   pair
calculate_logsums <- function(times, utilities, walkspeed = 2.8) {
  
  w_times <- times %>%
    pivot_wider(id_cols = c("resource", "blockgroup"), names_from = mode,
                values_from = c(duration, transfers, walktime, waittime, transittime)) %>%
    filter(!is.na(duration_CAR))
  
  lsum <- w_times %>%
    mutate(
      utility_CAR = as.numeric(
        utilities$CAR$constant + duration_CAR * utilities$CAR$ivtt
      ),
      utility_TRANSIT = as.numeric(
        utilities$TRANSIT$constant + 
          transittime_TRANSIT * utilities$TRANSIT$ivtt + 
          waittime_TRANSIT * utilities$TRANSIT$wait + 
          walktime_TRANSIT * utilities$TRANSIT$access
      ), 
      utility_WALK = as.numeric(
        utilities$WALK$constant + 
          duration_WALK * utilities$WALK$ivtt + 
          ifelse(walktime_WALK > utilities$WALK$distance_threshold,
                 # minutes * hr / min * mi/hr *  util / mi
                 walktime_WALK / 60 * walkspeed * utilities$WALK$long_distance,
                 walktime_WALK / 60 * walkspeed * utilities$WALK$short_distance
          )
      ), 
      
    ) %>%
    select(blockgroup, resource, contains("utility")) %>%
    pivot_longer(cols = contains("utility"), 
                 names_to = "mode", names_prefix = "utility_", values_to = "utility") %>%
    group_by(resource, blockgroup) %>%
    summarise(mclogsum = logsum(utility))
  
  left_join(w_times, lsum, by = c("resource", "blockgroup"))
  
}

logsum <- function(utility){
  log(sum(exp(utility), na.rm = TRUE))
}

prob_u <- function(utility){
  exp(utility) / sum(exp(utility), na.rm = TRUE)
}

read_utilities <- function(file){
  
  read_json(file, simplifyVector = TRUE)
  
}
  


#' Get American Community Survey data for the study.
#' 
#' @param state Which state to pull for
#' @param county Which county(ies) to pull
#' 
get_acsdata <- function(state = "UT", county = "Utah") {
  variables <- c(
    "population" = "B02001_001", # TOTAL: RACE
    "housing_units" = "B25001_001", # HOUSING UNITS
    "households" = "B19001_001", #HOUSEHOLD INCOME IN THE PAST 12 MONTHS (IN 2017 INFLATION-ADJUSTED DOLLARS)
    # Hispanic or Latino Origin by Race
    "white" = "B03002_003",
    "black" = "B03002_004",
    "asian" = "B03002_006",
    "hispanic" = "B03002_012",
    #MEDIAN HOUSEHOLD INCOME IN THE PAST 12 MONTHS (IN 2017 INFLATION-ADJUSTED DOLLARS)
    "income" = "B19013_001",
    # FAMILY TYPE BY PRESENCE AND AGE OF RELATED CHILDREN
    "children_c06" = "B11004_004", # married under 6 only
    "children_c6+" = "B11004_005", # married under 6 and older
    "children_m06" = "B11004_011", # male under 6 only
    "children_m6+" = "B11004_012", # male under 6 and older
    "children_f06" = "B11004_017", # female under 6 only
    "children_f6+" = "B11004_018", # female under 6 and older
    #HOUSEHOLD INCOME IN THE PAST 12 MONTHS (IN 2017 INFLATION-ADJUSTED DOLLARS)
    "inc_0010" = "B19001_002",  "inc_1015" = "B19001_003", "inc_1520" = "B19001_004",
    "inc_2025" = "B19001_005", "inc_2530" = "B19001_006", "inc_3035" = "B19001_007",
    "inc_125"  = "B19001_015", "inc_150"  = "B19001_016", "inc_200"  = "B19001_017"
  )
  
  get_acs(geography = "block group", variables = variables, year = 2019,
                 state = state, county = county, geometry = TRUE) %>%
    select(-moe) %>%
    spread(variable, estimate) %>%
    # area is in m^2, change to km^2
    mutate(area = as.numeric(st_area(geometry) * 1e-6)) %>%
    transmute(
      geoid = GEOID,
      group = 1,
      population, households, housing_units, 
      density = households / area,
      income,
      # many of the variables come in raw counts, but we want to consider
      # them as shares of a relevant denominator.
      children = 100 * ( children_c06 + `children_c6+` + 
                           children_m06 + `children_m6+` + 
                           children_f06 + `children_f6+`) / households,
      lowincome    = 100 * (inc_0010 + inc_1015 + inc_1520 + inc_2530 +
                              inc_3035) / households,
      highincome   = 100 * (inc_125 + inc_150 + inc_200) / households,
      black        = 100 * black / population,
      asian        = 100 * asian / population,
      hispanic     = 100 * hispanic / population,
      white        = 100 * white / population
    ) %>%
    filter(population > 0) %>%
    st_set_geometry(NULL) %>%
    as_tibble()
}
