_ = require("lodash")
fs = require("fs-extra")
cp = require("child_process")
path = require("path")
glob = require("glob")
Promise = require("bluebird")

fs = Promise.promisifyAll(fs)
glob = Promise.promisify(glob)

DEFAULT_PATHS = "package.json".split(" ")

pathToPackageJson = (pkg) ->
  path.join(pkg, "package.json")

runAllBuild = ->
  new Promise (resolve, reject) ->
    reject = _.once(reject)

    ## build all the packages except for
    ## cli and docs
    cp.spawn("npm", ["run", "all", "build", "--", "--skip-packages", "cli,docs"], { stdio: "inherit" })
    .on "error", reject
    .on "exit", (code) ->
      if code is 0
        resolve()
      else
        reject(new Error("'npm run build' failed with exit code: #{code}"))


copyAllToDist = (distDir) ->
  copyRelativePathToDist = (relative) ->
    dest = path.join(distDir, relative)

    console.log(relative, "->", dest)

    fs.copyAsync(relative, dest)

  copyPackage = (pkg) ->
    ## copies the package to dist
    ## including the default paths
    ## and any specified in package.json files
    fs.readJsonAsync(pathToPackageJson(pkg))
    .then (json) ->
      ## grab all the files
      ## and default included paths
      ## and convert to relative paths
      DEFAULT_PATHS
      .concat(json.files or [])
      .map (file) ->
        path.join(pkg, file)
      .map(copyRelativePathToDist, {concurrency: 1})

        ## fs-extra concurrency tests (copyPackage / copyRelativePathToDist)
        ## 1/1  41688
        ## 1/5  42218
        ## 1/10 42566
        ## 2/1  45041
        ## 2/2  43589
        ## 3/3  51399

        ## cp -R concurrency tests
        ## 1/1 65811

  started = new Date()

  fs.ensureDirAsync(distDir)
  .then ->
    glob("./packages/*")
    .map(copyPackage, {concurrency: 1})
  .then ->
    console.log("Finished Copying", new Date() - started)
  .delay(10000)

npmInstallAll = (pathToPackages) ->
  ## 1,060,495,784 bytes (1.54 GB on disk) for 179,156 items
  ## 313,416,512 bytes (376.6 MB on disk) for 23,576 items

  started = new Date()

  retryGlobbing = ->
    glob(pathToPackages)
    .catch {code: "EMFILE"}, ->
      ## wait 1 second then retry
      Promise
      .delay(1000)
      .then(retryGlobbing)

  npmInstall = (pkg) ->
    console.log("npm installing", pkg)

    new Promise (resolve, reject) ->
      reject = _.once(reject)

      ## ignore node_modules/.bin due to symlinking
      cp.spawn("npm", ["install", "--production"], {
        cwd: pkg
        stdio: "inherit"
      })
      .on("error", reject)
      .on("exit", (code) ->
        if code is 0
          resolve()
        else
          reject(new Error("'npm install --production' on #{pkg} failed with exit code: #{code}"))
      )

  retryNpmInstall = (pkg) ->
    npmInstall(pkg)
    .catch {code: "EMFILE"}, ->
      Promise
      .delay(1000)
      .then ->
        retryNpmInstall(pkg)
    .catch (err) ->
      console.log(err, err.code)
      throw err

  ## prunes out all of the devDependencies
  ## from what was copied
  retryGlobbing()
  .map(retryNpmInstall)
  .then ->
    console.log("Finished NPM Installing", new Date() - started)

symlinkAll = (distDir) ->
  pathToPackages = path.join('node_modules', '@')
  pathToDistPackages = distDir("packages", "*")

  symlink = (pkg) ->
    # console.log(pkg, dist)
    ## strip off the initial './'
    ## ./packages/foo -> node_modules/@packages/foo
    dest = path.join(distDir(), "node_modules", "@packages", path.basename(pkg))

    fs.ensureSymlinkAsync(pkg, dest)

  glob(pathToDistPackages)
  .map(symlink)

module.exports = {
  runAllBuild

  copyAllToDist

  npmInstallAll

  symlinkAll
}
