#!/bin/bash
set -e

# Each test will be performed 3 times
iterations=3

# Mount path for blobfuse is supplied on command line while executing this script
mount_dir=$1

# Name of tests we are going to perform
test_name=$2

# Directory where output logs will be generated by fio
output="./${test_name}"

# Additional mount parameters
log_type="syslog"
log_level="log_err"
cache_path=""

# --------------------------------------------------------------------------------------------------
# Method to mount blobfuse and wait for system to stabilize
mount_blobfuse() {
  set +e

  # Remove anything present in the mount dir/ temp dir before mounting
  if [ -d "/mnt/blob_mnt" ]; then
    rm -rf /mnt/blob_mnt/*
  fi
  
  if [ -d "/mnt/tempcache" ]; then
    rm -rf /mnt/tempcache/*
  fi

  blobfuse2 mount ${mount_dir} --config-file=./config.yaml --log-type=${log_type} --log-level=${log_level} ${cache_path}
  mount_status=$?
  set -e
  if [ $mount_status -ne 0 ]; then
    echo "Failed to mount file system"
    exit 1
  else
    echo "File system mounted successfully on ${mount_dir}"
  fi

  # Wait for daemon to come up and stablise
  sleep 10

  df -h | grep blobfuse
  df_status=$?
  if [ $df_status -ne 0 ]; then
    echo "Failed to find blobfuse mount"
    exit 1
  else
    echo "File system stable now on ${mount_dir}"
  fi
}

# --------------------------------------------------------------------------------------------------
# Method to execute fio command for a given config file and generate summary result
execute_test() {
  job_file=$1

  job_name=$(basename "${job_file}")
  job_name="${job_name%.*}"

  echo -n "Running job ${job_name} for ${iterations} iterations... "

  for i in $(seq 1 $iterations);
  do
    echo -n "${i};"
    set +e

    timeout 300m fio --thread \
      --output=${output}/${job_name}trial${i}.json \
      --output-format=json \
      --directory=${mount_dir} \
      --eta=never \
      ${job_file}

    job_status=$?
    set -e
    if [ $job_status -ne 0 ]; then
      echo "Job ${job_name} failed : ${job_status}"
      exit 1
    fi
  done

  # From the fio output get the bandwidth details and put it in a summary file
  jq -n 'reduce inputs.jobs[] as $job (null; .name = $job.jobname | .len += 1 | .value += (if ($job."job options".rw == "read")
      then $job.read.bw / 1024
      elif ($job."job options".rw == "randread") then $job.read.bw / 1024
      elif ($job."job options".rw == "randwrite") then $job.write.bw / 1024
      else $job.write.bw / 1024 end)) | {name: .name, value: (.value / .len), unit: "MiB/s"}' ${output}/${job_name}trial*.json | tee ${output}/${job_name}_bandwidth_summary.json

  # From the fio output get the latency details and put it in a summary file
  jq -n 'reduce inputs.jobs[] as $job (null; .name = $job.jobname | .len += 1 | .value += (if ($job."job options".rw == "read")
      then $job.read.lat_ns.mean / 1000000
      elif ($job."job options".rw == "randread") then $job.read.lat_ns.mean / 1000000
      elif ($job."job options".rw == "randwrite") then $job.write.lat_ns.mean / 1000000
      else $job.write.lat_ns.mean / 1000000 end)) | {name: .name, value: (.value / .len), unit: "milliseconds"}' ${output}/${job_name}trial*.json | tee ${output}/${job_name}_latency_summary.json
}

# --------------------------------------------------------------------------------------------------
# Method to iterate over fio files in given directory and execute each test
iterate_fio_files() {
  jobs_dir=$1
  job_type=$(basename "${jobs_dir}")

  for job_file in "${jobs_dir}"/*.fio; do
    job_name=$(basename "${job_file}")
    job_name="${job_name%.*}"
    
    mount_blobfuse
    
    execute_test $job_file

    blobfuse2 unmount all
    sleep 10

    rm -rf ~/.blobfuse2/*
  done
}

# --------------------------------------------------------------------------------------------------
# Method to list files on the mount path and generate report
list_files() {
  # Mount blobfuse and creat files to list
  mount_blobfuse
  total_seconds=0

  # List files and capture the time related details
  work_dir=`pwd`
  cd ${mount_dir}
  /usr/bin/time -o ${work_dir}/lst.txt -v ls -U --color=never > ${work_dir}/lst.out
  cd ${work_dir}
  cat ${work_dir}/lst.txt

  # Extract Elapsed time for listing files
  list_time=`cat ${work_dir}/lst.txt | grep "Elapsed" | rev | cut -d " " -f 1 | rev`
  echo $list_time

  IFS=':'; time_fragments=($list_time); unset IFS;
  list_min=`printf '%5.5f' ${time_fragments[0]}`
  list_sec=`printf '%5.5f' ${time_fragments[1]}`

  avg_list_time=`printf %5.5f $(echo "scale = 10; ($list_min * 60) + $list_sec" | bc)`

  # ------------------------------
  # Measure time taken to delete these files
  cat ${work_dir}/lst.out | wc -l  
  cat ${work_dir}/lst.out | rev | cut -d " " -f 1 | rev | tail +2  > ${work_dir}/lst.out1

  cd ${mount_dir}
  /usr/bin/time -o ${work_dir}/del.txt -v xargs rm -rf < ${work_dir}/lst.out1
  cd -
  cat ${work_dir}/del.txt

  # Extract Deletion time 
  del_time=`cat del.txt | grep "Elapsed" | rev | cut -d " " -f 1 | rev`
  echo $del_time

  IFS=':'; time_fragments=($del_time); unset IFS;
  del_min=`printf '%5.5f' ${time_fragments[0]}`
  del_sec=`printf '%5.5f' ${time_fragments[1]}`
  
  avg_del_time=`printf %5.5f $(echo "scale = 10; ($del_min * 60) + $del_sec" | bc)`

  # Unmount and cleanup now
  blobfuse2 unmount all
  sleep 10

  echo $avg_list_time " : " $avg_del_time

  jq -n --arg list_time $avg_list_time --arg del_time $avg_del_time '[{name: "list_100k_files", value: $list_time, unit: "seconds"},
      {name: "delete_100k_files", value: $del_time, unit: "seconds"}] ' | tee ${output}/list_results.json
}

# --------------------------------------------------------------------------------------------------
# Method to run read/write test using a python script
read_write_using_app() {

  # Clean up the results
  rm -rf ${output}/app_write_*.json
  rm -rf ${output}/app_read_*.json

  # ----- Write tests -----------
  # Mount blobfuse and creat files to list
  mount_blobfuse

  # Run the python script to write files
  echo `date` ' : Starting write tests'
  for i in {1,10,40,100} 
  do
    echo `date` " : Write test for ${i} GB file"
    python3 ./perf_testing/scripts/write.py ${mount_dir} ${i} > ${output}/app_write_${i}.json
  done

  # Unmount and cleanup now
  blobfuse2 unmount all
  sleep 10

  cat ${output}/app_write_*.json

  # ----- Read tests -----------
  # Mount blobfuse and creat files to list
  mount_blobfuse

  # Run the python script to read files
  echo `date` ' : Starting read tests'
  for i in {1,10,40,100} 
  do
    echo `date` " : Read test for ${i} GB file"
    python3 ./perf_testing/scripts/read.py ${mount_dir} ${i} > ${output}/app_read_${i}.json
  done

  rm -rf ${mount_dir}/application_*

  # Unmount and cleanup now
  blobfuse2 unmount all
  sleep 10

  cat ${output}/app_read_*.json

  # Local SSD Writing just for comparison
  # echo `date` ' : Starting Local write tests'
  # for i in {1,10,40,100} 
  # do
  #   echo `date` ' : Write test for ${i} GB file'
  #   python3 ./perf_testing/scripts/write.py ${mount_dir} ${i} > ${output}/app_local_write_${i}.json
  # done
  # rm -rf ${mount_dir}/*


  # ----- HighSpeed tests -----------
  # Mount blobfuse 
  mount_blobfuse
  rm -rf ${mount_dir}/20GFile*

  # Run the python script to read files
  echo `date` ' : Starting highspeed tests'
  python3 ./perf_testing/scripts/highspeed_create.py ${mount_dir} 10 > ${output}/highspeed_app_write.json
  
  blobfuse2 unmount all
  sleep 10

  mount_blobfuse

  python3 ./perf_testing/scripts/highspeed_read.py ${mount_dir}/20GFile* > ${output}/highspeed_app_read.json
  rm -rf ${mount_dir}/20GFile*

  # Unmount and cleanup now
  blobfuse2 unmount all
  sleep 10

  cat ${output}/highspeed_app_*.json

  # Generate output
  jq '{"name": .name, "value": .speed, "unit": .unit}' ${output}/app_write_*.json ${output}/app_read_*.json | jq -s '.' | tee ./${output}/app_bandwidth.json
  jq '{"name": .name, "value": .total_time, "unit": "seconds"}' ${output}/app_write_*.json ${output}/app_read_*.json | jq -s '.' | tee ./${output}/app_time.json

  jq '{"name": .name, "value": .speed, "unit": .unit}' ${output}/highspeed_app*.json | jq -s '.' | tee ./${output}/highapp_bandwidth.json
  jq '{"name": .name, "value": .total_time, "unit": "seconds"}' ${output}/highspeed_app*.json | jq -s '.' | tee ./${output}/highapp_time.json

  # jq '{"name": .name, "value": .speed, "unit": .unit}' ${output}/app_local_write_*.json | jq -s '.' | tee ./${output}/app_local_bandwidth.json
}

# --------------------------------------------------------------------------------------------------
# Method to create and then rename files
rename_files() {
  # ----- Rename tests -----------
  # Mount blobfuse
  mount_blobfuse

  total_seconds=0

  # List files and capture the time related details
  work_dir=`pwd`
  cd ${mount_dir}
  python3 ${work_dir}/perf_testing/scripts/rename.py > ${work_dir}/rename.json
  cd ${work_dir}
  cat rename.json

  jq '{"name": .name, "value": .rename_time, "unit": .unit}' ${work_dir}/rename.json | jq -s '.' | tee ./${output}/rename_time.json
}

# --------------------------------------------------------------------------------------------------
# Method to prepare the system for test
prepare_system() {
  blobfuse2 unmount all
  sleep 10
  # Clean up logs and create output directory
  mkdir -p ${output}
  chmod 777 ${output}
}


# --------------------------------------------------------------------------------------------------
# Prepare the system for test
prepare_system

# --------------------------------------------------------------------------------------------------
executed=1
if [[ ${test_name} == "write" ]] 
then
  # Execute write benchmark using fio
  echo "Running Write test cases"
  #cache_path="--block-cache-path=/mnt/tempcache"
  iterate_fio_files "./perf_testing/config/write" 
  
elif [[ ${test_name} == "read" ]] 
then
  # Execute read benchmark using fio
  echo "Running Read test cases"
  iterate_fio_files "./perf_testing/config/read" 
elif [[ ${test_name} == "highlyparallel" ]] 
then
  # Execute multi-threaded benchmark using fio
  echo "Running Highly Parallel test cases"
  #cache_path="--block-cache-path=/mnt/tempcache"
  iterate_fio_files "./perf_testing/config/high_threads"
elif [[ ${test_name} == "create" ]] 
then  
  # Set log type to silent as this is going to generate a lot of logs
  log_type="silent"
  iterations=1

  # Pre creation cleanup
  mount_blobfuse
  echo "Deleting old data"
  cd ${mount_dir}
  find . -name "create_1000_files_in_10_threads*" -delete  
  find . -name "create_1000_files_in_100_threads*" -delete  
  find . -name "create_1l_files_in_20_threads*" -delete  
  cd -
  ./blobfuse2 unmount all
  sleep 10

  # Execute file create tests
  echo "Running Create test cases"
  iterate_fio_files "./perf_testing/config/create" 
elif [[ ${test_name} == "list" ]] 
then 
  # Set log type to silent as this is going to generate a lot of logs
  log_type="silent"
  
  # Execute file listing tests
  echo "Running File listing test cases"
  list_files 
  
  # No need to generate bandwidth or latecy related reports in this case
  executed=0 
elif [[ ${test_name} == "app" ]] 
then  
  # App based read/write tests being executed
  # This is done using a python script which read/write in sequential order
  echo "Running App based tests"
  read_write_using_app

  # No need to generate bandwidth or latecy related reports in this case
  executed=0
elif [[ ${test_name} == "rename" ]] 
then 
  # Set log type to silent as this is going to generate a lot of logs
  log_type="silent"

  # Execute rename tests
  echo "Running File rename test cases"
  rename_files
  
  # No need to generate bandwidth or latecy related reports in this case
  executed=0 
else
  executed=0  
  echo "Invalid argument. Please provide either 'read', 'write', 'multi' or 'create' as argument"
fi

# --------------------------------------------------------------------------------------------------
if [[ $executed -eq 1 ]] 
then
  # Merge all results and generate a json summary for bandwidth
  jq -n '[inputs]' ${output}/*_bandwidth_summary.json | tee ./${output}/bandwidth_results.json

  # Merge all results and generate a json summary for latency
  jq -n '[inputs]' ${output}/*_latency_summary.json | tee ./${output}/latency_results.json
fi

# --------------------------------------------------------------------------------------------------
