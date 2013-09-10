namespace :hospitals do

  task :ensure_fields_are_properly_formatted do
    Hospital.all.each do |h|
      h.update_attribute("PROVIDER CCN",format_ccn(h["PROVIDER CCN"]))
      h.update_attribute("PROVIDER ZIP 5 CD",add_leading_zeros(h["PROVIDER ZIP 5 CD"],5)) unless h["PROVIDER ZIP 5 CD"].to_s.length == 0
      h.update_attribute("PROVIDER ZIP 4 CD",add_leading_zeros(h["PROVIDER ZIP 4 CD"],4)) unless h["PROVIDER ZIP 4 CD"].to_s.length == 0
      h.rename(:"PROVIDER / ORG NAME",:"PROVIDER - ORG NAME") # rename field so it is mongoexport-able
    end
  end

  desc "Add General Hospital Info to datastore if they are not already in it"
  task :ingest_general_info do
    puts "#{Hospital.count} hospitals in db"

    socrata_endpoint = "http://data.medicare.gov/resource/v287-28n3.json"
    all_hospitals = fetch_whole_socrata_dataset(socrata_endpoint, settings.socrata_key)

    puts "Ingesting new data"
    all_hospitals.each do |general_row|
      new_general_data = {
        "_source" => socrata_endpoint,
        "_updated_at" => Time.now,
      }.merge(general_row)
      h = Hospital.find_by("PROVIDER CCN" => format_ccn(new_general_data["provider_number"]))
      if h.nil?
        Hospital.create("general" => new_general_data, "PROVIDER CCN" => format_ccn(new_general_data["provider_number"]))
      else
        h.update_attributes("general" => new_general_data)
      end
    end
    puts "#{Hospital.count} hospitals in db"
  end


  desc "Fetch HCAHPS hospital data from Socrata API for hospitals that are already in our system"
  task :ingest_hcahps do
    socrata_endpoint = "http://data.medicare.gov/resource/rj76-22dk.json"

    puts "Number of hospitals in collection: #{Hospital.count}"
    hospitals_without_hcahps = Hospital.without_hcahps
    puts "Number of hospitals in collection w/o HCAHPS: #{hospitals_without_hcahps.count}"

    hcahps_data = fetch_whole_socrata_dataset(socrata_endpoint, settings.socrata_key)

    puts "Ingesting new data"
    hcahps_data.each do |hcahps_row|
      new_hcahps_data = {
        "_source" => socrata_endpoint,
        "_updated_at" => Time.now,
      }.merge(hcahps_row)
      h = Hospital.find_by("PROVIDER CCN" => format_ccn(new_hcahps_data["provider_number"]))
      if h.nil?
        Hospital.create("hcahps" => new_hcahps_data, "PROVIDER CCN" => format_ccn(new_hcahps_data["provider_number"]))
      else
        h.update_attribute("hcahps",new_hcahps_data)
      end
    end
    
    puts "#{Hospital.count} hospitals in db"
    puts "Number of hospitals in collection w/o HCAHPS: #{Hospital.without_hcahps.count}"
  end

  desc "Using a CSV mapping file, bring in Joint Commission IDs so we can link to qualitycheck.org"
  task :ingest_joint_commission_ids do
    require 'csv'

    puts "Number of hospitals in collection: #{Hospital.count}"
    puts "Number of hospitals in collection w/o JC org id: #{Hospital.without_jc_id.count}"

    CSV.foreach("public/data/hospital_jc_id-to-medicare_ccn.csv") do |row|
      h = Hospital.find_by("PROVIDER CCN" => row[1])
      unless h.nil?
        jc_data = {"org_id" => row[0].to_i, "_updated_at" => Time.now, "_source" => "Extracted via qualitycheck.org"}
        h.update_attribute("jc",jc_data)
      end
    end

    puts "Number of hospitals in collection w/o JC org id: #{Hospital.without_jc_id.count}"
    
  end

  desc "Fetch HAI (hospital acquired infection) data from Socrata API for hospitals that are already in our system (aka received incentive payments)"
  task :ingest_hc_hais do
    socrata_endpoint = "http://data.medicare.gov/resource/ihvx-zkyp.json"

    hc_hai_data = fetch_whole_socrata_dataset(socrata_endpoint, settings.socrata_key, 1000, "score is not null")

    puts "Ingesting new data"
    hc_hai_data.each do |hc_hai_row|
      hc_hai_row = {
        "_source" => socrata_endpoint,
        "_updated_at" => Time.now,
      }.merge(hc_hai_row)
      ["hospital_name","phone_number","zip_code","state","address_1","city","county_name"].each {|k| hc_hai_row.delete(k)}
      h = Hospital.find_by("PROVIDER CCN" => format_ccn(hc_hai_row["provider_id"]))
      if h.nil?
        new_h = Hospital.create("PROVIDER CCN" => format_ccn(hc_hai_row["provider_id"]))
        new_h.hc_hais << HcHai.new(hc_hai_row)
      else
        h.hc_hais << HcHai.new(hc_hai_row)
      end
    end
    
  end

  desc "Fetch AHRQ Measures from Socrata API"
  task :ingest_ahrq_m do
    socrata_endpoint = "http://data.medicare.gov/resource/vs3q-rxc5.json"

    puts "Number of hospitals in collection: #{Hospital.count}"
    hospitals_without_ahrq_m = Hospital.without_ahrq_m
    puts "Number of hospitals in collection w/o AHRQ measures: #{hospitals_without_ahrq_m.count}"

    data = fetch_whole_socrata_dataset(socrata_endpoint, settings.socrata_key)

    puts "Ingesting new data"
    data.each do |row|
      new_data = {
        "_source" => socrata_endpoint,
        "_updated_at" => Time.now,
      }.merge(row)
      h = Hospital.find_by("PROVIDER CCN" => format_ccn(new_data["provider_number"]))
      if h.nil?
        Hospital.create("ahrq_m" => new_data, "PROVIDER CCN" => format_ccn(new_data["provider_number"]))
      else
        h.update_attribute("ahrq_m",new_data)
      end
    end
    
    puts "#{Hospital.count} hospitals in db"
    puts "Number of hospitals in collection w/o AHRQ Measures: #{Hospital.without_ahrq_m.count}"
  end


  #desc "Calculate HCAHPS national averages for each value and store in a hcahps_averages collection"
  #task :calculate_national_averages do
  #  # find out what fields we need to calculate averages for
  #  array_of_fields = Hospital.where("hcahps" => {"$ne" => nil}).first["hcahps"].keys
  #  array_of_fields.each do |field|
  #    Hospital.mr_compute_descriptive_stats_excluding_nulls("hcahps.#{field}")
  #  end
  #end

  task :simple_report do
    puts "\nWe started by analyzing hospitals that received incentive payments in program year 2011, 2012, or 2013. We then added all hospitals in the hospital compare (general information) data set, and added HCAHPS data for as many hospitals as we could, using their CCN as the look-up variable.\n\n"
    # Documents with a root-level key of "PROGRAM YEAR 2012" DID receive incentive payments
    puts "  # received an incentive* (* in any of 2011, 2012, _or_ 2013) = #{Hospital.received_any_incentives.count}"
    puts "    # received an incentive* and we were able to geocode = #{Hospital.received_any_incentives.with_geo.count}"
    puts "    # received an incentive* and we found HCAHPS data = #{Hospital.received_any_incentives.with_hcahps.count}"
    puts "    # received an incentive* and we found general information = #{Hospital.received_any_incentives.with_general.count}"
    puts "    # received an incentive* and we found a Joint Commission ID = #{Hospital.received_any_incentives.with_jc_id.count}"
    puts " -> # received an incentive* and we found general information, HCAHPS, and geocoded = #{Hospital.received_any_incentives.with_general.with_hcahps.with_geo.count} (#{(Hospital.received_any_incentives.with_general.with_hcahps.with_geo.count/Hospital.received_any_incentives.count.to_f*100).round}% of ones that received incentives) \n\n"
    puts "  # did not received an incentive*  = #{Hospital.never_received_any_incentives.count}"
    puts "    # did not received an incentive* and we were able to geocode = #{Hospital.never_received_any_incentives.with_geo.count}"
    puts "    # did not received an incentive* and we found HCAHPS data = #{Hospital.never_received_any_incentives.with_hcahps.count}"
    puts "    # did not received an incentive* and we found general information = #{Hospital.never_received_any_incentives.with_general.count}"
    puts "    # did not received an incentive* and we found Joint Commission ID = #{Hospital.never_received_any_incentives.with_jc_id.count} \n\n"

    puts "TOTAL HOSPITALS IN DB = #{Hospital.count} (# received any incentives* + # never received an incentive)\n\n"

  end


end
