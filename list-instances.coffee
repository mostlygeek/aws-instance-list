AWS = require "aws-sdk"
async = require "async"
request = require "request"


# Expect that AWS_ACCESS_KEY and AWS_SECRET_KEY env. vars are 
# available. These are the ones that the regular EC2 CLI tools
# use. WTF Amazon, why can't you keep these consistent?

unless process.env.AWS_ACCESS_KEY?
    console.error "Env. var: AWS_ACCESS_KEY does not exist"
    process.exit 1
unless process.env.AWS_SECRET_KEY?
    console.error "Env. var: AWS_SECRET_KEY does not exist"
    process.exit 1

AWS.config.update
    accessKeyId     : process.env.AWS_ACCESS_KEY
    secretAccessKey : process.env.AWS_SECRET_KEY
    region          : "us-east-1"


new AWS.EC2().describeRegions (err, regionData) ->
    return console.log(err) if err?

    # 
    # Creates a callback for `async` so we can run these requests in parallel
    #
    makeReq = (region) ->
        (cb) ->
            opts =
                accessKeyId     : process.env.AWS_ACCESS_KEY
                secretAccessKey : process.env.AWS_SECRET_KEY
                region          : region

            new AWS.EC2(opts).describeInstances (err, instanceList) ->
                return console.log(err) if err?
                return console.log("Nothing to show in: #{region.RegionName}") unless instanceList.Reservations?

                instances = []
                for r in instanceList.Reservations
                    for instance in r.Instances
                        #console.log instance
                        instData =
                            id   : instance.InstanceId

                            # parsed out of Tags
                            name : "NOT_SET"

                            # runtime info minutes
                            launch: instance.LaunchTime
                            runtime: Math.floor((Date.now() - (Date.parse instance.LaunchTime))/1000/3600)

                            status: instance.State.Name
                            type : instance.InstanceType

                            # the SSH key on the box
                            key: instance.KeyName
                            dns: instance.PublicDnsName

                            tags: []

                        for tag in instance.Tags
                            if tag.Key == "Name"
                                instData.name = tag.Value

                            instData.tags.push "#{tag.Key}=#{tag.Value}"

                        instances.push instData

                cb(null, instances)
            return


    parReqs = {}
    for region in regionData.Regions
        parReqs[region.RegionName] = makeReq(region.RegionName)

    async.parallel
        "pricing": (cb) ->

            # make a regionb based pricing chart
            makePriceStub = ->
                    'm1.small'   : -1
                    'm1.medium'  : -1
                    'm1.large'   : -1
                    'm1.xlarge'  : -1

                    't1.micro'   : -1

                    'm2.xlarge'  : -1
                    'm2.2xlarge' : -1
                    'm2.4xlarge' : -1

                    'c1.medium'  : -1
                    'c1.xlarge'  : -1

                    'cc1.4xlarge': -1
                    'cc2.8xlarge': -1
                    'cg1.4xlarge': -1

            prices =
                'us-east-1'      : makePriceStub()
                'us-west-2'      : makePriceStub()
                'us-west-1'      : makePriceStub()
                'eu-west-1'      : makePriceStub()
                'ap-southeast-1' : makePriceStub()
                'ap-northeast-1' : makePriceStub()
                'sa-east-1'      : makePriceStub()


            # 
            # Return useful blob of info on pricing
            # ref: http://stackoverflow.com/a/9840802
            #
            url  = "http://aws.amazon.com/ec2/pricing/pricing-on-demand-instances.json"
            request url, (err, req, body) ->
                return cb(err) if err?

                try
                    pricing = JSON.parse body

                catch e
                    return cb("JSON Parse Error: #{e}")

                for reg in pricing.config.regions
                    regKey = switch reg.region
                        when 'us-east'      then 'us-east-1'
                        when 'us-west-2'    then 'us-west-2'
                        when 'us-west'      then 'us-west-1'
                        when 'eu-ireland'   then 'eu-west-1'
                        when 'apac-sin'     then 'ap-southeast-1'
                        when 'apac-tokyo'   then 'ap-northeast-1'
                        when 'sa-east-1'    then 'sa-east-1'
                        else reg.region


                    # this monstrosity parses it into a happy
                    # little look up blob
                    for iType in reg.instanceTypes
                        for sizes in iType.sizes
                            for value in sizes.valueColumns
                                continue if value.name != "linux"
                                type = iType.type
                                size = sizes.size
                                price = parseFloat value.prices.USD

                                instanceType = switch type
                                    when "stdODI"
                                        switch size
                                            when "sm" then "m1.small"
                                            when "med" then "m1.medium"
                                            when "lg" then "m1.large"
                                            when "xl" then "m1.xlarge"
                                            else "m1.unknown"
                                    when "uODI"
                                        switch size
                                            when "u" then "t1.micro"
                                            else "t1.unknown"
                                    when "hiMemODI"
                                        switch size
                                            when "xl" then "m2.xlarge"
                                            when "xxl" then "m2.2xlarge"
                                            when "xxxxl" then "m2.4xlarge"
                                            else "m2.unknown"
                                    when "hiCPUODI"
                                        switch size
                                            when "med" then "c1.medium"
                                            when "xl" then "c1.xlarge"
                                            else "c1.unknown"
                                    when "clusterComputeI"
                                        switch size
                                            when "xxxxl" then "cc1.4xlarge"
                                            when "xxxxxxxxl" then "cc2.8xlarge"
                                            else "cc2.unknown"
                                    when "clusterGPUI"
                                        switch size
                                            when "xxxxl" then "cg1.4xlarge"
                                            else "cg1.unknown"
                                    when "hiIoODI"
                                        switch size
                                            when "xxxxl" then "hi1.4xlarge"
                                            else "hi1.unknown"
                                    when "hiStoreODI"
                                        switch size
                                            when "xxxxxxxxl" then "hs1.8xlarge"
                                            else "hs1.unknown"
                                    else
                                        "unknown(#{type},#{size})"

                                #console.log regKey, instanceType, price

                                if prices[regKey]?[instanceType]? and ! isNaN(price)
                                    prices[regKey][instanceType] = price
                        
                cb(null, prices)
                return

        "running": (cb) ->
            async.parallel parReqs, cb

    , (err, results) ->
        return console.log("ERROR: #{err}") if err?

        pricing = results.pricing

        console.log "region,id,dns,type,status,uptime,price_hourly,name,keyname,tags"
        for regName,instances of results.running
            for i in instances

                price = if pricing[regName]?[i.type]? then pricing[regName][i.type] else -1

                tags = i.tags.join(", ")
                csv = [regName, i.id, i.dns, i.type, i.status, i.runtime, price, i.name, i.key, tags].join('","')
                #csv = csv.substring 0, csv.length - 1
                console.log "\"#{csv}\""

        return

    return
