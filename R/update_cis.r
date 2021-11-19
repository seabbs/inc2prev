library("here")
library("readxl")
library("rvest")
library("tidyr")
library("dplyr")
library("lubridate")
library("ggplot2")
library("purrr")
library("janitor")
library("lubridate")
library("socialmixr")

## create directory for CIS if it doesn't exist
cis_dir <- here::here("data", "cis")
dir.create(cis_dir, showWarnings = FALSE, recursive = TRUE)

## creata URLs that list spreadsheets
years <- c(2020 + seq(0, 1))
urls <- paste0("https://www.ons.gov.uk/peoplepopulationandcommunity/",
              "healthandsocialcare/conditionsanddiseases/datasets/",
              "coronaviruscovid19infectionsurveydata/", years)

## get URLs of the spreadsheets, scraped from the web pages
file_urls <- lapply(urls, function(url) {
  session <- session(url)
  file_url <- session %>%
    html_nodes(xpath = paste0(
                 "//a[contains(concat(' ', ",
                 "normalize-space(@class),' '),' btn--primary ')]"
               )) %>%
    html_attr("href")
  return(file_url)
}) %>%
  unlist() %>%
  grep("\\.xlsx?$", value = TRUE, .)

## construct tibble with files to download
df_dl <- tibble(file_url = file_urls) %>%
  mutate(file_name = sub("^.*/([^/]+)$", "\\1", file_url),
         file_path = file.path(cis_dir, file_name),
         full_url = paste0("https://www.ons.gov.uk", file_url)) %>%
  filter(!file.exists(file_path))

## if no new URLs there is nothing to do
if (nrow(df_dl) > 0) {
  df_dl %>%
    rowwise() %>%
    mutate(ret = download.file(full_url, file_path))
  if (any(df_dl$ret != 0)) warning("Some downloads failed")
}

## define geography codes not in data
geography_codes <- c(England = "E92000001",
                     `North East` = "E12000001",
                     `North West` = "E12000002",
                     `Yorkshire and The Humber` = "E12000003",
                     `East Midlands` = "E12000004",
                     `West Midlands` = "E12000005",
                     `East of England` = "E12000006",
                     `London` = "E12000007",
                     `South East` = "E12000008",
                     `South West` = "E12000009")

## define levels to extract and table structure
columns <- c(national = 4, regional = 5, local = 6, age_school = 5)
super_headers <- c(regional = "region", age_school = "lower_age_limit")

## list all files
files <- list.files(here::here("data", "cis"), full.names = TRUE)
list_file <- here::here("data", "cis_files.rds")

if (file.exists(list_file) && setequal(files, readRDS(list_file))) {
  stop("Nothing new to extract")
}

## manual override for problematic spreadsheet (wrong table label in contents)
override <- list(`covid19infectionsurveydatasets20210305v2.xlsx` =
                   list(`1b` = "1b ",
                        `1k` = "1l",
                        `1h` = "1i"))

## construct list of data frames with positivity
positivity <- list()
for (level in names(columns)) {
  positivity[[level]] <- lapply(files, function(x) {
    ## first,  get table of contents sheet to work out which sheet we want
    contents_sheet <- read_excel(x, sheet = "Contents") %>%
      clean_names()
    if (level == "national") {
      contents_sheet <- contents_sheet %>%
        filter(grepl("daily", contents)) %>%
        head(n = 1)
    } else if (level == "regional") {
      contents_sheet <- contents_sheet %>%
        filter(grepl("daily", contents),
               grepl("(Region|region$)", contents )) %>%
        head(n = 1)
    } else if (level == "local") {
      contents_sheet <- contents_sheet %>%
        filter(grepl("CIS sub-region", contents)) %>%
        head(n = 1)
    } else if (level == "age_school") {
      contents_sheet <- contents_sheet %>%
        filter(grepl("daily", contents),
               grepl("age/school year$", contents)) %>%
        head(n = 1)
    } else {
      stop("Unknown level: ", level)
    }
    ## extract table number
    sheet <- sub("^Table ([^ ]+) ?- .*$", "\\1", contents_sheet$contents)
    if (length(sheet) == 1) {
      ## manual override
      if (basename(x) %in% names(override) &&
          sheet %in% names(override[[basename(x)]])) {
        sheet <- override[[basename(x)]][[sheet]]
      }
      ## we found the sheet, now we get a preview so we can work out where in
      ## the sheet the actual table is
      preview <- read_excel(x, sheet = sheet) %>%
        remove_empty("cols") %>%
        clean_names()
      if (level %in% c("national", "regional", "age_school")) {
        headers_row <- min(grep("(%|[Nn]umber)", unlist(preview[, 2]))) - 1
        skip <- headers_row + 1
        if (level %in% c("regional", "age_school")) {
          headers <- preview[headers_row, 2:ncol(preview)] %>%
            t() %>%
            as_tibble(.name_repair = "minimal") %>%
            rename(header = 1) %>%
            fill(header)
          if (level == "age_school") {
            headers <- headers %>%
              mutate(header = sub("School Year 6", "Age 10", header),
                     header = sub("School Year 7", "Age 11", header),
                     header = sub("School Year 11", "Age 15", header),
                     header = sub("School Year 12", "Age 16", header)) %>%
              mutate(header = sub("^Age ([0-9]+).* to Age ([0-9]+).*$", "\\1|\\2", header),
                     header = sub("^Age ([0-9]+)\\+", "\\1|", header)) %>%
              separate(header, c("from", "to"), sep = "\\|")
          }
        }
      } else if (level == "local") {
        skip <- which(preview$contents == "Geography Code")
        ## work out the date of the survey
        date_end <- dmy(sub("^.* to ", "", preview$contents[3]))
        date_start <- date_end - 6
      }
      ## having figured out where the table is and extracted the date, read the table
      if (is.infinite(skip)) return(NULL) ## couldn't find data
      data <- read_excel(x, sheet = sheet, skip = skip, .name_repair = "minimal") %>%
        remove_empty("cols") %>%
        clean_names()
      if (level %in% c("national", "regional", "age_school")) {
        colnames(data) <-
          c("date", sub("(estimated_)?(.+)_[0-9]+$", "\\2", colnames(data)[2:ncol(data)]))
        if (level == c("regional")) {
          colnames(data)[2:ncol(data)] <-
            paste(colnames(data)[2:ncol(data)], headers$header, sep = "|")
        } else if (level == "age_school") {
          colnames(data)[2:ncol(data)] <-
            paste(colnames(data)[2:ncol(data)], headers$from, sep = "|")
        }
        data <- data[, !duplicated(colnames(data))]
        data <- data %>%
          filter(grepl("^[0-9]+", date)) %>%
          mutate(date = if_else(grepl("^[0-9]+$", date),
                                as.Date(as.integer(date), origin = "1899-12-30"),
                                dmy(date))) %>%
          filter(!is.na(date)) %>%
          mutate_at(2:ncol(.), as.numeric) %>%
          pivot_longer(2:ncol(.))
        if (level %in% names(super_headers)) {
          data <- data %>%
            separate(name, c("name", super_headers[level]), sep = "\\|")
        }
        data <- data %>%
          mutate(name = sub("covid_19", "covid", name)) %>% ## sometimes _19 gets removed by colnames manipulation above
          pivot_wider()
        if (level == "age_school") {
          data <- data %>%
            mutate(lower_age_limit = as.integer(lower_age_limit))
        }
      } else if (level == "local") {
        data <- data %>%
          filter(!is.na(geography_code),
                 !is.na(region))
      }
      data <- data %>%
        select(1:columns[level]) %>%
        rename(percentage_pos = columns[[level]] - 2,
               percentage_pos_low_95 = columns[[level]] - 1,
               percentage_pos_high_95 = columns[[level]]) %>%
        mutate_at(vars(starts_with("percentage")), as.numeric) %>%
        filter(!is.na(percentage_pos)) %>%
        pivot_longer(starts_with("percentage")) %>%
        replace_na(list(value = 0)) %>%
        pivot_wider()
      if (level %in% c("national", "regional", "age_school")) {
        if (level %in% c("national", "age_school")) {
          data <- data %>%
            mutate(region = NA_character_,
                   geography = "England")
        } else if (level == "regional") {
          data <- data %>%
            mutate(region = sub("the Humber", "The Humber", region)) %>%
            mutate(geography = region)
        }
        data <- data %>%
          mutate(geography_code = geography_codes[geography])
      } else if (level == "local") {
        data <- data %>%
          rename(geography = local_authority_areas) %>%
          mutate(start_date = date_start,
                 end_date = date_end)
      }
      if ("date" %in% colnames(data)) {
        data <- data %>%
          mutate(start_date = date,
                 end_date = date)
      }
       if (level == "age_school") {
        data <- data %>%
          mutate(lower_age_limit = as.integer(lower_age_limit)) %>%
          select(start_date, end_date, geography, geography_code,
                 lower_age_limit, starts_with("percentage"))
      } else {
       data <- data %>%
          select(start_date, end_date, geography, geography_code,
                 region, starts_with("percentage"))
      }
     return(data %>%
             mutate(file_name = x))
    } else {
      return(NULL)
    }
  })
  positivity[[level]] <- positivity[[level]] %>%
    bind_rows() %>%
    distinct() %>% ## avoid duplicate rows
    mutate(level = level)
}

## combine it all into one data frame
combined <- positivity %>%
  bind_rows() %>%
  group_by(file_name) %>%
  mutate(report_date = max(end_date)) %>%
  ungroup() %>%
  arrange(report_date, start_date)

## annoyingly, sometimes percentages are reported on the decimal scale
percent_dates <- combined %>%
  select(report_date, level) %>%
  distinct() %>%
  mutate(must_divide =
           (level == "national" &
            report_date > "2020-06-27" & report_date < "2020-07-19") |
           (level != "national" & report_date < "2020-07-19") |
           report_date > "2021-06-12")

combined <- combined %>%
  left_join(percent_dates, by = c("report_date", "level")) %>%
  pivot_longer(starts_with("percentage")) %>%
  mutate(value = if_else(must_divide, value / 100, value),
         name = sub("percentage", "proportion", name)) %>%
  pivot_wider() %>%
  select(-must_divide)

aggregated <- combined %>%
  pivot_longer(starts_with("proportion")) %>%
  group_by(level, start_date, end_date, name, lower_age_limit,
           geography, geography_code, region) %>%
  summarise(value = median(value), .groups = "drop") %>%
  pivot_wider()

## save area mapping, correcting for LAD21 changes
areas <- combined %>%
  filter(level == "local") %>%
  select(geography_code, region, geography) %>%
  distinct() %>%
  mutate(lad = strsplit(geography, "; ")) %>%
  select(-geography) %>%
  unnest(lad) %>%
  mutate(lad = if_else(lad %in% c("Suffolk Coastal", "Waveney"),
                       "East Suffolk",
                       lad),
         lad = if_else(lad %in% c("Forest Heath", "St Edmundsbury"),
                       "West Suffolk",
                       lad),
         lad = if_else(lad %in% c("Taunton Deane", "West Somerset"),
                       "Somerset West and Taunton",
                       lad),
         lad = if_else(lad %in% c("Bournemouth", "Poole", "Christchurch"),
                       "Bournemouth, Christchurch and Poole",
                       lad),
         lad = if_else(lad %in% c("East Dorset", "North Dorset", "West Dorset", "Purbeck", "Weymouth and Portland"),
                       "Dorset",
                       lad),
         lad = if_else(lad %in% c("Aylesbury Vale", "Chiltern", "South Bucks", "Wycombe"),
                       "Buckinghamshire",
                       lad),
         lad = if_else(lad %in% c("Corby", "East Northamptonshire", "Kettering", "Wellingborough"),
                       "North Northamptonshire",
                       lad),
         lad = if_else(lad %in% c("Daventry", "Northampton", "South Northamptonshire"),
                       "West Northamptonshire",
                       lad)) %>%
  rename(ltla_name = lad)

## get population estimates
pop_file <- here::here("data", "uk_pop.xls")
if (!file.exists(pop_file)) {
  download.file("https://www.ons.gov.uk/file?uri=%2fpeoplepopulationandcommunity%2fpopulationandmigration%2fpopulationestimates%2fdatasets%2fpopulationestimatesforukenglandandwalesscotlandandnorthernireland%2fmid2020/ukpopestimatesmid2020on2021geography.xls", destfile = pop_file)
}
pop <- read_excel(pop_file, sheet = "MYE2 - Persons", skip = 7) %>%
  clean_names()
pop_geo <- pop %>%
  mutate(all_caps_geography = sub("[^a-zA-Z]*$", "", toupper(name))) %>%
  select(all_caps_geography, population = all_ages) %>%
  mutate(all_caps_geography =
           recode(all_caps_geography, EAST = "EAST OF ENGLAND"))
pop_age <- pop %>%
  filter(name == "ENGLAND") %>%
  select(starts_with("x")) %>%
  pivot_longer(everything(), names_to = "lower_age_limit") %>%
  mutate(lower_age_limit = as.integer(sub("^x", "", lower_age_limit)),
         lower_age_limit =
           reduce_agegroups(lower_age_limit,
                            unique(na.omit(combined$lower_age_limit)))) %>%
  filter(!is.na(lower_age_limit)) %>%
  group_by(lower_age_limit) %>%
  summarise(age_population = sum(value), .groups = "drop")
pop_local <- areas %>%
  mutate(all_caps_geography = toupper(ltla_name)) %>%
  left_join(pop_geo, by = "all_caps_geography") %>%
  group_by(geography_code) %>%
  summarise(local_population = sum(population), .groups = "drop")

aggregated <- aggregated %>%
  mutate(all_caps_geography = toupper(geography)) %>%
  left_join(pop_geo, by = "all_caps_geography") %>%
  left_join(pop_age, by = "lower_age_limit") %>%
  left_join(pop_local, by = "geography_code") %>%
  mutate(population = if_else(!is.na(age_population),
                              age_population, population),
         population = if_else(!is.na(local_population),
                              local_population, population)) %>%
  select(-all_caps_geography, -age_population, -local_population)

## save
saveRDS(aggregated %>%
        filter(level %in% c("national", "regional", "local")) %>%
        remove_empty(which = "cols"),
        here::here("data", "cis.rds"))
saveRDS(aggregated %>%
        filter(level %in% c("age_school")) %>%
        remove_empty(which = "cols"),
        here::here("data", "cis_age.rds"))
saveRDS(areas, here::here("data", "cis_areas.rds"))
saveRDS(files, list_file)
