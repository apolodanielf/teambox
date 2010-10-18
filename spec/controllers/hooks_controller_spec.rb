require 'spec_helper'

describe HooksController do
  it "should route to hooks controller" do
    params_from(:post, '/hooks/email').should == {
      :action => "create", :hook_name => "email", :controller => "hooks"
    }
  end
  
  it "should route to hooks controller scoped under project" do
    params_from(:post, '/projects/12/hooks/pivotal').should == {
      :action => "create", :hook_name => "pivotal", :controller => "hooks", :project_id => "12"
    }
  end

  describe "#create" do
    before do
      @project = Factory(:project)
    end

    describe "emails" do
      it "should parse incoming emails to new conversation" do
        post_email_hook  @project.permalink,
                                'Random latin text',
                                'Lorem ipsum dolor sit amet, ...',
                                false

        response.should be_success
        conversation = @project.conversations.last(:order => 'id asc')
        conversation.name.should == 'Random latin text'
        conversation.comments.last.body.should == 'Lorem ipsum dolor sit amet, ...'
        conversation.comments.last.uploads.count.should == 0
      end

      it "should parse incoming emails with attachments to new conversation" do
        post_email_hook  @project.permalink,
                                'Hey, check this awesome file!',
                                'Lorem ipsum dolor sit amet, ...'

        response.should be_success
        conversation = @project.conversations.last(:order => 'id asc')
        conversation.name.should == 'Hey, check this awesome file!'
        conversation.comments.last.body.should == 'Lorem ipsum dolor sit amet, ...'
        conversation.comments.last.uploads.count.should == 2
        conversation.comments.last.uploads.first(:order => 'id asc').asset_file_name.should == 'tb-space.jpg'
      end
      
      it "handles encoded headers" do
        post :create,
             :hook_name => 'email',
             :from => @project.user.email,
             :to => "=?ISO-8859-1?Q?Moo?= <#{@project.permalink}@#{Teambox.config.smtp_settings[:domain]}>\n",
             :text => "Hello there",
             :subject => "Just testing"
        
        response.should be_success
        comment = @project.conversations.last(:order => 'id asc').comments.first
        comment.body.should == "Hello there"
      end
      
      it "ignores email with missing info" do
        post :create,
             :hook_name => 'email',
             :from => '',
             :to => "#{@project.permalink}@#{Teambox.config.smtp_settings[:domain]}",
             :text => "Hello there",
             :subject => "Just testing"
        
        response.should be_success
        response.body.should == "Invalid From field"
      end
      
      it "ignores email without plaintext part" do
        post :create,
             :hook_name => 'email',
             :from => @project.user.email,
             :to => "#{@project.permalink}@#{Teambox.config.smtp_settings[:domain]}",
             :html => "<p>Hello there</p>",
             :subject => "Just testing"
        
        response.should be_success
        response.body.should == "Invalid mail body"
      end
      
      it "ignores email with invalid 'to' address" do
        post :create,
             :hook_name => 'email',
             :from => @project.user.email,
             :to => "me@moo.com",
             :text => "Hello there",
             :subject => "Just testing"
        
        response.should be_success
        response.body.should == "Invalid To fields"
      end

      it "should parse incoming emails with attachments to conversation answers" do
        @task = Factory(:task, :project => @project)
        
        post_email_hook "#{@project.permalink}+task+#{@task.id}",
                        '',
                        'I would say something about this task'

        comment = @task.comments(true).last
        comment.body.should == 'I would say something about this task'
        comment.uploads.count.should == 2
      end

      it "should parse incoming emails with attachments to task answers" do
        @conversation = Factory(:conversation, :project => @project)
        
        post_email_hook "#{@project.permalink}+conversation+#{@conversation.id}",
                        '',
                        'I would say something about this conversation'

        comment = @conversation.comments(true).last(:order => 'id asc')
        comment.body.should == 'I would say something about this conversation'
        comment.uploads.count.should == 2
      end
      
      context "the bounce system" do
        before do
          @options = post_options("#{@project.permalink}+task", 'Some subject', 'I would say something about this task')
        end
        
        it "should raise (200 for sendgrid) and create a bounce message if an unknown user posts to a project" do
          options =  @options.merge!(:from => 'random_person@teambox.com')
          check_bounce_message(options) do
            post :create, options
          end
          response.response_code.should == 200
        end
        
        it "should raise (200 for sendgrid) and create a bounce message if a user does not belong to a project" do
          options =  @options.merge!(:from => Factory(:user).email)
          check_bounce_message(options) do
            post :create, options
          end
          response.response_code.should == 200
        end
      
        it "should raise (200 for sendgrid) and create a bounce message if a project is not found" do |variable|
          options = @options.merge!(:to => "#{@project.permalink}+task+#{rand(1000) + 1000}@#{Teambox.config.smtp_settings[:domain]}")
          check_bounce_message(options) do
            post :create, options
          end
          response.response_code.should == 200
        end
        
        it "should raise (200 for sendgrid) and create a bounce message if a conversation is not found" do |variable|
          options = @options.merge(:to => "#{@project.permalink}+conversation+#{rand(1000) + 1000}@#{Teambox.config.smtp_settings[:domain]}")
          check_bounce_message(options) do
            post :create, options
          end
          response.response_code.should == 200
        end
      
        it "should only create one bounce message every day if an exception is raised" do
          options =  @options.merge!(:from => Factory.build(:user).email) # Do not save just build for email
          Emailer.should_receive(:deliver_bounce_message).once
          
          post :create, options
          post :create, options
        end
      end
      
      def check_bounce_message(options, &block)
        Emailer.should_receive(:deliver_bounce_message).with(
          kind_of(Emailer::Incoming::Error)
        ).once
        
        lambda do
          yield
        end.should change(EmailBounce, :count).by(1)
      end
      
      def post_email_hook(to, subject, body, attachments = true)
        post :create, post_options(to, subject, body, attachments)
      end
      
      def post_options(to, subject, body, attachments = true)
         {
           :hook_name => 'email',
           :method => :post,
           :from => @project.user.email,
           :to => "#{to}@#{Teambox.config.smtp_settings[:domain]}",
           :text => body,
           :subject => subject,
           :attachments => attachments ? '2' : nil,
           :attachment1 => upload_file("#{Rails.root}/spec/fixtures/tb-space.jpg", 'image/jpg'),
           :attachment2 => upload_file("#{Rails.root}/spec/fixtures/users.yml", 'text/plain')
         }
      end
    end
    
    describe "Pivotal Tracker" do
      before do
        @payload = {"activity"=>
          {"author"=>"James Kirk",
            "project_id"=>26,
            "occurred_at"=>Time.parse("Mon Dec 14 22:12:09 UTC 2009"),
            "id"=>1031,
            "version"=>175,
            "description"=>'James Kirk accepted "More power to shields"',
            "event_type"=>"story_update",
            "stories"=>
            {"story"=>
              {"current_state"=>"accepted",
                "name"=>"More power to shields",
                "accepted_at"=>Time.parse("Mon Dec 14 22:12:09 UTC 2009"),
                "url"=>"https:///projects/26/stories/109",
                "id"=>109}}}}
      end
      
      def post
        super :create, @payload.merge(:hook_name => 'pivotal', :project_id => @project.id)
      end
      
      it "creates a new task list" do
        post
        response.should be_success
        
        task_list = @project.task_lists.first
        task_list.name.should == "Pivotal Tracker"
        
        task = task_list.tasks.first
        task.name.should == "More power to shields [PT109]"
        task.status_name.should == :resolved
        task.comments.first.body.should == "James Kirk marked the task as accepted on #PT"
      end
      
      it "ignores unknown task status" do
        @payload['activity']['stories']['story']['current_state'] = "smokin'!"
        post
        task = Task.first
        task.status_name.should == :new
      end
    end
    
    describe "GitHub" do
      it "posts to the project timeline" do
        payload = <<-JSON
          {
            "before": "5aef35982fb2d34e9d9d4502f6ede1072793222d",
            "repository": {
              "url": "http://github.com/defunkt/github",
              "name": "github",
              "description": "You're lookin' at it.",
              "watchers": 5, "forks": 2, "private": 1,
              "owner": { "email": "chris@ozmm.org", "name": "defunkt" }
            },
            "commits": [
              {
                "id": "41a212ee83ca127e3c8cf465891ab7216a705f59",
                "url": "http://github.com/defunkt/github/commit/41a212ee83ca127e3c8cf465891ab7216a705f59",
                "author": { "email": "chris@ozmm.org", "name": "Chris Wanstrath" },
                "message": "okay i give in",
                "timestamp": "2008-02-15T14:57:17-08:00",
                "added": ["filepath.rb"]
              },
              {
                "id": "de8251ff97ee194a289832576287d6f8ad74e3d0",
                "url": "http://github.com/defunkt/github/commit/de8251ff97ee194a289832576287d6f8ad74e3d0",
                "author": { "email": "chris@ozmm.org", "name": "Chris Wanstrath" },
                "message": "update pricing a tad",
                "timestamp": "2008-02-15T14:36:34-08:00"
              }
            ],
            "after": "de8251ff97ee194a289832576287d6f8ad74e3d0",
            "ref": "refs/heads/master"
          }
        JSON
        
        post :create, :payload => payload, :hook_name => 'github', :project_id => @project.id
        
        conversation = @project.conversations.first
        conversation.should be_simple
        conversation.name.should be_nil
        
        expected = (<<-HTML).strip
        <div class='hook_github'><h3>New code on <a href='http://github.com/defunkt/github'>github</a> refs/heads/master</h3>

Chris Wanstrath - <a href='http://github.com/defunkt/github/commit/41a212ee83ca127e3c8cf465891ab7216a705f59'>okay i give in</a><br>
Chris Wanstrath - <a href='http://github.com/defunkt/github/commit/de8251ff97ee194a289832576287d6f8ad74e3d0'>update pricing a tad</a><br>
</div>
        HTML
        
        conversation.comments.first.body.should == expected
      end
    end
  end
end